import Foundation

/// 待播清单七个查询的纯逻辑：参数校验、结果构造、字幕搜索。不碰 `QueueStore` 和主线程，
/// 应用端在主线程取好条目，交给这里算出可直接编码的 JSON 对象。
enum QueueAgentQuery {
    static let listDefaultLimit = 100
    static let listLimitRange = 1...500
    static let maxMoveItems = 200
    static let maxLinks = 50
    static let maxLinkLength = 2048
    static let searchDefaultLimit = 20
    static let searchLimitRange = 1...100
    static let maxQueryLength = 200
    static let maxChapters = 200
    static let maxChapterTitleLength = 120
    static let maxChapterSummaryLength = 300
    static let readDefaultCues = 400
    static let readCueRange = 1...2000
    /// 播放器用 Int64、每秒 600 个时间刻度。留出舍入余量，避免极大 JSON 数字溢出。
    static let maxTimestampSeconds = Double(Int64.max / 1200)

    // MARK: - 错误

    /// 工具级错误：放在工具结果里（`isError: true`），agent 看得到原因。`details` 并进返回的 JSON。
    struct Failure: Error {
        let code: String
        let message: String
        var details: [String: Any] = [:]

        static let invalidArguments = "invalid_arguments"
        static let itemNotFound = "item_not_found"
        static let queueUnreadable = "queue_unreadable"
        static let notPlayable = "not_playable"
        static let outOfRange = "out_of_range"
        static let chaptersUserEdited = "chapters_user_edited"
        static let noSubtitles = "no_subtitles"

        static func invalid(_ message: String, _ details: [String: Any] = [:]) -> Failure {
            Failure(code: invalidArguments, message: message, details: details)
        }

        static func notFound(_ missing: [String]) -> Failure {
            Failure(
                code: itemNotFound,
                message: "没有这些条目，什么都没改：\(missing.joined(separator: "、"))。先用 list_queue 查条目编号。",
                details: ["missingItemIDs": missing]
            )
        }

        static let unreadable = Failure(
            code: queueUnreadable,
            message: "seesee 读不出待播清单文件 queue.json，这时不接受任何修改，什么都没改。请用户在 seesee 里处理后再试。"
        )

        static let backupFailed = Failure(
            code: "queue_backup_failed",
            message: "升级前备份没有成功，本次运行只读，什么都没改。请重新打开 seesee，备份成功后再试。"
        )
        static let writeFailed = Failure(
            code: "queue_write_failed",
            message: "写入待播清单失败，改动仍在当前内存中，尚未保存。恢复可写后下次保存会重试，请勿当作已落盘。"
        )

        var payload: [String: Any] {
            details.merging(["error": code, "message": message]) { _, new in new }
        }
    }

    // MARK: - 参数

    /// 字符串或字符串数组都接受；其他类型、空字符串算错。
    static func strings(_ value: Any?, name: String) throws -> [String]? {
        guard let value, !(value is NSNull) else { return nil }
        if let single = value as? String { return [single] }
        guard let array = value as? [Any] else { throw Failure.invalid("\(name) 应是字符串数组") }
        return try array.map { element in
            guard let string = element as? String else { throw Failure.invalid("\(name) 里每一项都应是字符串") }
            return string
        }
    }

    static func statuses(_ value: Any?) throws -> Set<WatchStatus>? {
        guard let raw = try strings(value, name: "status") else { return nil }
        var result = Set<WatchStatus>()
        for name in raw {
            guard let status = WatchStatus(rawValue: name) else {
                throw Failure.invalid("不认识的状态「\(name)」。只有这五个：\(statusGlossary)")
            }
            result.insert(status)
        }
        return result
    }

    static var statusGlossary: String {
        WatchStatus.allCases.map { "\($0.rawValue)（\($0.displayName)）" }.joined(separator: "、")
    }

    /// 数字；JSON 的 true/false 不算数字。
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        return double.isFinite ? double : nil
    }

    static func clampedInt(_ value: Any?, default fallback: Int, range: ClosedRange<Int>) -> Int {
        guard let number = number(value) else { return fallback }
        // 先限制 Double，再转 Int，避免合法 JSON 中的极大数字让服务崩溃。
        if number <= Double(range.lowerBound) { return range.lowerBound }
        if number >= Double(range.upperBound) { return range.upperBound }
        return Int(number.rounded())
    }

    static func bool(_ value: Any?, name: String, default fallback: Bool) throws -> Bool {
        guard let value, !(value is NSNull) else { return fallback }
        guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
            throw Failure.invalid("\(name) 应是 true 或 false")
        }
        return flag.boolValue
    }

    /// 条目编号：按 UUID 解析，大小写都行。解析不了的也算不存在。
    static func itemIDs(_ raw: [String], existing: (UUID) -> Bool) -> (ids: [UUID], missing: [String]) {
        var ids: [UUID] = []
        var seen = Set<UUID>()
        var missing: [String] = []
        for string in raw {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: trimmed), existing(id) else {
                missing.append(string)
                continue
            }
            if seen.insert(id).inserted { ids.append(id) }
        }
        return (ids, missing)
    }

    static func singleItemID(_ value: Any?) throws -> String {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalid("缺少 item_id（条目编号，用 list_queue 查）")
        }
        return string
    }

    // MARK: - 条目对象

    static func itemObject(_ item: WatchItem, previewPlayable: Bool) -> [String: Any] {
        let duration = finitePositive(item.duration)
        let position = item.playbackPosition.flatMap { $0.isFinite && $0 >= 0 && $0 <= maxTimestampSeconds ? $0 : nil }
        var progressPercent: Any = NSNull()
        if let duration, let position {
            progressPercent = Int(min(100, max(0, (position / duration * 100).rounded())))
        }
        var object: [String: Any] = [
            "itemID": item.id.uuidString,
            "title": item.titleDisplay.primary,
            "author": item.author,
            "source": item.sourceName,
            "sourceURL": webURL(item.urlString) ?? NSNull(),
            "videoID": YouTubeVideoID.extract(from: item.urlString) ?? NSNull(),
            "status": item.status.rawValue,
            "statusName": item.status.displayName,
            "statusIsManual": item.statusIsManual,
            "durationSeconds": duration.map { rounded($0) } ?? NSNull(),
            "duration": duration.map(NowPlayingQuery.timecode) ?? NSNull(),
            "positionSeconds": position.map { rounded($0) } ?? NSNull(),
            "position": position.map(NowPlayingQuery.timecode) ?? NSNull(),
            "progressPercent": progressPercent,
            "addedAt": isoString(item.addedAt),
            "watchedAt": item.watchedAt.map(isoString) ?? NSNull(),
            "download": [
                "state": item.state.rawValue,
                "progress": rounded(min(1, max(0, item.progress.isFinite ? item.progress : 0))),
                "label": item.progressLabel,
                "error": item.errorMessage ?? NSNull(),
                "previewPlayable": previewPlayable
            ] as [String: Any],
            "transcription": transcriptionObject(item),
            "translationSource": item.translationSource ?? NSNull(),
            "translationPolishable": item.translationPolishable,
            "originalCorrectable": item.originalCorrectable,
            "hasSubtitles": item.subtitleFileURL != nil,
            "chapterCount": item.availableChapters.count,
            "chapterSource": item.chapterSource.rawValue
        ]
        object.merge(titleFields(item)) { _, new in new }
        return object
    }

    static func transcriptionObject(_ item: WatchItem) -> [String: Any] {
        var result: [String: Any] = ["state": item.transcriptionState ?? "not_needed"]
        if item.transcriptionState == "failed" { result["error"] = item.transcriptionError ?? "转写失败" }
        if let code = item.transcriptionErrorCode { result["errorCode"] = code }
        result["automaticRetryCount"] = max(0, item.transcriptionAutomaticRetryCount ?? 0)
        if let language = item.transcriptionLanguage { result["language"] = language }
        if item.transcriptionLanguageFallback == true { result["languageFallback"] = true }
        return result
    }

    /// 标题翻译五字段逐字返回；缺少的值为 null。
    static func titleFields(_ item: WatchItem) -> [String: Any] {
        [
            "originalTitle": item.originalTitle ?? NSNull(),
            "translatedTitle": item.translatedTitle ?? NSNull(),
            "translatedTitleSource": item.translatedTitleSource ?? NSNull(),
            "customTitle": item.customTitle ?? NSNull(),
            "postText": item.postText ?? NSNull()
        ]
    }

    // MARK: - list_queue

    /// `ordered` 是界面上的顺序：先待播清单，再「已看」分组。
    static func listQueue(
        _ ordered: [WatchItem],
        arguments: AgentLinkArguments,
        previewPlayable: (UUID) -> Bool
    ) throws -> [String: Any] {
        let filter = try statuses(arguments["status"])
        let limit = clampedInt(arguments["limit"], default: listDefaultLimit, range: listLimitRange)
        let offset = clampedInt(arguments["offset"], default: 0, range: 0...Int.max / 2)
        var counts: [String: Int] = [:]
        for status in WatchStatus.allCases { counts[status.rawValue] = 0 }
        for item in ordered { counts[item.status.rawValue, default: 0] += 1 }
        let matching = ordered.filter { filter?.contains($0.status) ?? true }
        let page = matching.dropFirst(offset).prefix(limit)
        return [
            "counts": counts,
            "total": matching.count,
            "returned": page.count,
            "offset": offset,
            "items": page.map { itemObject($0, previewPlayable: previewPlayable($0.id)) }
        ]
    }

    // MARK: - move_items

    static func moveTarget(_ arguments: AgentLinkArguments) throws -> (ids: [String], target: WatchStatus) {
        guard let raw = try strings(arguments["item_ids"], name: "item_ids"), !raw.isEmpty else {
            throw Failure.invalid("缺少 item_ids（要挪的条目编号，用 list_queue 查）")
        }
        guard raw.count <= maxMoveItems else {
            throw Failure.invalid("一次最多挪 \(maxMoveItems) 条，这次给了 \(raw.count) 条")
        }
        guard let name = arguments["to"] as? String else {
            throw Failure.invalid("缺少 to（目标状态）。可选：\(statusGlossary)")
        }
        guard let target = WatchStatus(rawValue: name) else {
            throw Failure.invalid("不认识的状态「\(name)」。只有这五个：\(statusGlossary)")
        }
        return (raw, target)
    }

    static func moveResult(target: WatchStatus, before: [WatchItem], requested: [UUID], after: (UUID) -> WatchItem?) -> [String: Any] {
        let movedIDs = Set(before.map(\.id))
        let moved: [[String: Any]] = before.map { old in
            ["itemID": old.id.uuidString, "title": old.title, "from": old.status.rawValue, "to": after(old.id)?.status.rawValue ?? target.rawValue]
        }
        let unchanged: [[String: Any]] = requested.filter { !movedIDs.contains($0) }.compactMap { id in
            guard let item = after(id) else { return nil }
            return ["itemID": id.uuidString, "title": item.titleDisplay.primary, "status": item.status.rawValue]
        }
        return ["to": target.rawValue, "moved": moved, "unchanged": unchanged]
    }

    // MARK: - add_links

    enum LinkDecision {
        case accepted(input: String, url: URL)
        case rejected(input: String, reason: String)
    }

    /// 逐项判断能不能加。只用 `URLIntake.webURLs(from:)` 识别链接，不用 `URLIntake.resolve(_:)`：
    /// 后者遇到 file:// 会去读那个文件的内容，agent 传 file:///etc/passwd 时应用不能去读。
    static func linkDecisions(_ arguments: AgentLinkArguments) throws -> [LinkDecision] {
        guard let raw = try strings(arguments["urls"], name: "urls"), !raw.isEmpty else {
            throw Failure.invalid("缺少 urls（要加入的链接）")
        }
        guard raw.count <= maxLinks else {
            throw Failure.invalid("一次最多加 \(maxLinks) 个链接，这次给了 \(raw.count) 个")
        }
        var seen = Set<String>()
        var decisions: [LinkDecision] = []
        for input in raw {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let decision = decide(input: input, trimmed: trimmed)
            if case .accepted(_, let url) = decision {
                guard seen.insert(url.absoluteString).inserted else { continue }
            }
            decisions.append(decision)
        }
        return decisions
    }

    private static func decide(input: String, trimmed: String) -> LinkDecision {
        guard !trimmed.isEmpty else { return .rejected(input: input, reason: "这一项是空的") }
        guard trimmed.count <= maxLinkLength else {
            return .rejected(input: String(input.prefix(200)), reason: "链接超过 \(maxLinkLength) 个字符")
        }
        let scheme = URL(string: trimmed)?.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            return .rejected(input: input, reason: "只接受 http 或 https 网页链接")
        }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return .rejected(input: input, reason: "每一项只能是一个链接，不能带别的文字")
        }
        let found = URLIntake.webURLs(from: trimmed)
        guard found.count == 1, let url = found.first, url.host?.isEmpty == false else {
            return .rejected(input: input, reason: found.count > 1 ? "这一项里有好几个链接，请拆开" : "没认出网页链接")
        }
        guard !ChannelLink.isSubscription(url) else {
            return .rejected(input: input, reason: "频道和订阅链接不在这里加，请用户在 seesee 里粘贴并确认订阅")
        }
        return .accepted(input: input, url: url)
    }

    static func rejectedObject(input: String, reason: String) -> [String: Any] {
        ["input": input, "reason": reason]
    }

    // MARK: - seek_to

    static func seekArguments(_ arguments: AgentLinkArguments) throws -> (itemID: String, seconds: Double, play: Bool) {
        let itemID = try singleItemID(arguments["item_id"])
        guard let seconds = number(arguments["seconds"]) else {
            throw Failure.invalid("缺少 seconds（跳到第几秒），应是数字")
        }
        guard seconds >= 0 else { throw Failure.invalid("seconds 不能小于 0") }
        guard seconds <= maxTimestampSeconds else { throw Failure.invalid("seconds 超出播放器可表示的时间范围") }
        let play = try bool(arguments["play"], name: "play", default: false)
        return (itemID, seconds, play)
    }

    /// 没下好、也没有边下边播的预览时说明为什么不能播。
    static func notPlayableMessage(_ item: WatchItem, mediaFolderDisconnected: Bool) -> String {
        if mediaFolderDisconnected, item.state == .ready {
            return "《\(item.title)》存在没接上的磁盘里，现在播不了"
        }
        switch item.state {
        case .failed:
            return "《\(item.title)》下载失败：\(item.errorMessage ?? "原因不明")"
        case .queued:
            return "《\(item.title)》还在排队下载（\(item.progressLabel)），也还没有可以边下边播的预览"
        case .downloading:
            return "《\(item.title)》正在下载，还没有可以边下边播的预览，稍后再试"
        case .ready:
            return "《\(item.title)》的视频文件找不到了"
        }
    }

    // MARK: - write_chapters

    static func chapters(_ arguments: AgentLinkArguments, duration: Double?) throws -> [VideoChapter] {
        guard let raw = arguments["chapters"] as? [Any] else {
            throw Failure.invalid("缺少 chapters（章节数组，传空数组表示删掉你写的章节）")
        }
        guard raw.count <= maxChapters else {
            throw Failure.invalid("一个视频最多 \(maxChapters) 章，这次给了 \(raw.count) 章")
        }
        let knownDuration = finitePositive(duration)
        var result: [VideoChapter] = []
        for (index, element) in raw.enumerated() {
            func fail(_ reason: String) -> Failure {
                Failure.invalid("第 \(index + 1) 章（下标 \(index)）：\(reason)。什么都没写。", ["index": index])
            }
            guard let chapter = element as? [String: Any] else { throw fail("应是对象") }
            guard let start = number(chapter["start_seconds"]) else { throw fail("缺少 start_seconds，应是数字") }
            guard start >= 0 else { throw fail("start_seconds 不能小于 0") }
            guard start <= maxTimestampSeconds else { throw fail("start_seconds 超出播放器可表示的时间范围") }
            if let knownDuration, start >= knownDuration {
                throw Failure(
                    code: Failure.outOfRange,
                    message: "第 \(index + 1) 章（下标 \(index)）的 start_seconds \(start) 超出视频时长 \(NowPlayingQuery.timecode(knownDuration))（\(rounded(knownDuration)) 秒）。什么都没写。",
                    details: ["index": index, "durationSeconds": rounded(knownDuration)]
                )
            }
            guard let rawTitle = chapter["title"] as? String else { throw fail("缺少 title") }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw fail("title 是空的") }
            guard title.count <= maxChapterTitleLength else { throw fail("title 超过 \(maxChapterTitleLength) 个字符") }
            var summary: String?
            if let rawSummary = chapter["summary"], !(rawSummary is NSNull) {
                guard let text = rawSummary as? String else { throw fail("summary 应是字符串") }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count <= maxChapterSummaryLength else { throw fail("summary 超过 \(maxChapterSummaryLength) 个字符") }
                summary = trimmed.isEmpty ? nil : trimmed
            }
            result.append(VideoChapter(title: title, startTime: start, endTime: nil, summary: summary))
        }
        result.sort { $0.startTime < $1.startTime }
        for index in result.indices.dropFirst() where result[index].startTime == result[index - 1].startTime {
            throw Failure.invalid("有两章的开始时间都是 \(result[index].startTime) 秒。什么都没写。")
        }
        return result
    }

    // MARK: - 字幕

    struct SubtitleSource {
        let item: WatchItem
        let path: String?
    }

    /// 右栏字幕流显示的句子：按句末标点合并后的句块。读不出来或没有字幕时返回 nil。
    static func sentenceBlocks(path: String?) -> [VideoSubtitleCue]? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path),
              let track = VideoSubtitleTrack(contentsOf: url) else { return nil }
        return SubtitleSentenceBlocks.aggregate(track.cues)
    }

    /// 一句拆成原文和译文：第一行原文，其余译文，和 `NowPlayingQuery.cueObject` 同一拆法。
    static func split(_ cue: VideoSubtitleCue) -> (original: String, translation: String?) {
        SubtitleVersionStore.split(cue)
    }

    static func searchArguments(_ arguments: AgentLinkArguments) throws -> (query: String, limit: Int, ids: [String]?, statuses: Set<WatchStatus>?) {
        guard let raw = arguments["query"] as? String else { throw Failure.invalid("缺少 query（关键词）") }
        let query = DigestTranscriptSearch.normalizedQuery(raw)
        guard !query.isEmpty else { throw Failure.invalid("query 是空的") }
        guard query.count <= maxQueryLength else { throw Failure.invalid("query 超过 \(maxQueryLength) 个字符") }
        let limit = clampedInt(arguments["limit"], default: searchDefaultLimit, range: searchLimitRange)
        return (query, limit, try strings(arguments["item_ids"], name: "item_ids"), try statuses(arguments["status"]))
    }

    /// 在后台线程调用：逐个读字幕文件，匹配规则和右栏搜索框相同（去掉首尾空白、不区分大小写的子串）。
    static func search(_ sources: [SubtitleSource], query: String, limit: Int) -> [String: Any] {
        var results: [[String: Any]] = []
        var total = 0
        var searched = 0
        var withoutSubtitles = 0
        for source in sources {
            guard let blocks = sentenceBlocks(path: source.path) else {
                withoutSubtitles += 1
                continue
            }
            searched += 1
            for block in blocks {
                let (original, translation) = split(block)
                let inOriginal = original.range(of: query, options: .caseInsensitive) != nil
                let inTranslation = translation?.range(of: query, options: .caseInsensitive) != nil
                guard inOriginal || inTranslation else { continue }
                total += 1
                guard results.count < limit else { continue }
                results.append([
                    "itemID": source.item.id.uuidString,
                    "title": source.item.titleDisplay.primary,
                    "originalTitle": titleFields(source.item)["originalTitle"] ?? NSNull(),
                    "start": rounded(block.startTime),
                    "end": rounded(block.endTime),
                    "startText": NowPlayingQuery.timecode(block.startTime),
                    "original": original,
                    "translation": translation ?? NSNull(),
                    "matchedIn": inOriginal && inTranslation ? "both" : (inOriginal ? "original" : "translation")
                ])
            }
        }
        return [
            "query": query,
            "searchedVideos": searched,
            "videosWithoutSubtitles": withoutSubtitles,
            "totalMatches": total,
            "truncated": total > results.count,
            "results": results
        ]
    }

    static func readArguments(_ arguments: AgentLinkArguments) throws -> (itemID: String, start: Double, end: Double?, maxCues: Int, startIndex: Int) {
        let itemID = try singleItemID(arguments["item_id"])
        var start = 0.0
        if let raw = arguments["start_seconds"], !(raw is NSNull) {
            guard let value = number(raw), value >= 0 else { throw Failure.invalid("start_seconds 应是不小于 0 的数字") }
            start = value
        }
        var end: Double?
        if let raw = arguments["end_seconds"], !(raw is NSNull) {
            guard let value = number(raw), value > start else { throw Failure.invalid("end_seconds 应是大于 start_seconds 的数字") }
            end = value
        }
        let maxCues = clampedInt(arguments["max_cues"], default: readDefaultCues, range: readCueRange)
        let startIndex = try arguments["start_index"].map { try index($0) } ?? 0
        return (itemID, start, end, maxCues, startIndex)
    }

    private static func index(_ raw: Any) throws -> Int {
        guard let value = number(raw), value >= 0, value.rounded(.towardZero) == value, value < Double(Int.max) else {
            throw Failure.invalid("字幕编号应是不小于 0 的整数")
        }
        return Int(value)
    }

    static func translationArguments(_ arguments: AgentLinkArguments) throws -> (itemID: String, revision: String, translations: [SubtitleVersionStore.Translation]) {
        let itemID = try singleItemID(arguments["item_id"])
        guard let revision = arguments["revision"] as? String, !revision.isEmpty else { throw Failure.invalid("缺少读取整轨时的 revision") }
        guard let values = arguments["translations"] as? [[String: Any]], !values.isEmpty else { throw Failure.invalid("translations 应是非空译文数组") }
        let translations = try values.map { value -> SubtitleVersionStore.Translation in
            guard let rawIndex = value["index"] else { throw Failure.invalid("每项需要 index") }
            guard value["translation"] == nil || value["translation"] is String,
                  value["original"] == nil || value["original"] is String,
                  value["translation"] != nil || value["original"] != nil else {
                throw Failure.invalid("每项需有 translation 或 original 的文字内容")
            }
            return .init(index: try index(rawIndex), translation: value["translation"] as? String, original: value["original"] as? String)
        }
        return (itemID, revision, translations)
    }

    /// 在后台线程调用。按开始时间取 [start, end) 里的句子，一页最多 `maxCues` 句。
    static func readSubtitles(_ source: SubtitleSource, start: Double, end: Double?, maxCues: Int, startIndex: Int = 0) throws -> [String: Any] {
        let snapshot = try SubtitleVersionStore.snapshot(source.item)
        let blocks = snapshot.cues
        let inRange = blocks.enumerated().filter { index, block in
            guard index >= startIndex else { return false }
            guard block.startTime >= start else { return false }
            guard let end else { return true }
            return block.startTime < end
        }
        let page = inRange.prefix(maxCues)
        let next: Any = inRange.count > page.count ? inRange[page.count].element.startTime : NSNull()
        let nextIndex: Any = inRange.count > page.count ? inRange[page.count].offset : NSNull()
        let duration = finitePositive(source.item.duration)
        return [
            "itemID": source.item.id.uuidString,
            "title": source.item.titleDisplay.primary,
            "durationSeconds": duration.map { rounded($0) } ?? NSNull(),
            "totalCues": blocks.count,
            "returned": page.count,
            "nextStartSeconds": next,
            "nextIndex": nextIndex,
            "revision": snapshot.revision,
            "cues": page.map { index, block -> [String: Any] in
                let (original, translation) = snapshot.translationOnly ? ("", Optional(block.text)) : split(block)
                return [
                    "index": index,
                    "start": rounded(block.startTime),
                    "end": rounded(block.endTime),
                    "startText": NowPlayingQuery.timecode(block.startTime),
                    "original": original,
                    "translation": translation ?? NSNull()
                ]
            }
        ]
    }

    // MARK: - 小工具

    static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= maxTimestampSeconds else { return nil }
        return value
    }

    static func webURL(_ string: String) -> String? {
        guard let scheme = URL(string: string)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return string
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
