import Foundation

enum DownloadState: String, Codable {
    case queued
    case downloading
    case ready
    case failed
}

struct VideoChapter: Codable, Hashable, Identifiable {
    var title: String
    var startTime: Double
    var endTime: Double?
    /// 一句概括，只有 agent 写的章节有。
    var summary: String? = nil

    var id: String { "\(startTime)-\(title)" }
}

/// A playable source may be a finished local movie or the combined remote
/// stream exposed while the high-quality offline copy is still downloading.
struct VideoPlaybackSource: Equatable, Hashable {
    let videoURL: URL

    init(videoURL: URL) {
        self.videoURL = videoURL
    }
}

struct WatchItem: Identifiable, Codable, Hashable {
    let id: UUID
    var urlString: String
    /// 主标题：按用户改名、中文译名、原标题取第一个，由 `refreshTitle()` 算出，不单独写。
    /// 旧版 seesee 和只认 `title` 的工具读这一项。改标题走 `VideoTitle.swift` 里的几个方法。
    var title: String
    var author: String
    var duration: Double?
    var addedAt: Date
    var watchedAt: Date?
    var state: DownloadState
    var progress: Double
    var progressLabel: String
    var localFilePath: String?
    var errorMessage: String?
    var playbackPosition: Double?
    var chapters: [VideoChapter]?
    var thumbnailFilePath: String?
    var subtitleFilePath: String?
    /// 用户或 agent 手动定的待播清单状态，存 `WatchStatus` 的英文值；nil 表示没手动挪过，按推算规则算。
    /// 存字符串不存枚举：以后加了新状态，旧版本读到不认识的值时整个 queue.json 不会因此读不出来。
    var watchStatus: String? = nil
    /// 新加入、还没整理：新链接加入时为 true，任何一次手动挪动都清成 nil。
    var inInbox: Bool? = nil
    /// 新条目的真实连续播放证明。nil 是旧格式，仍按续播进度推算。
    var hasPlayedThreeSeconds: Bool? = nil
    /// agent 经 MCP 写的章节。视频自带的章节在 `chapters`，下载和刷新元数据时会被覆盖，这里不会。
    var agentChapters: [VideoChapter]? = nil
    /// 用户手动改过的章节。有值时 agent 不能写章节，显示也以它为准。
    var userChapters: [VideoChapter]? = nil
    /// 原标题，只由元数据写。旧条目没有这一项，读入时把旧的 `title` 当作原标题。
    var originalTitle: String? = nil
    /// 中文译名，只由翻译写。
    var translatedTitle: String? = nil
    /// 译名来源，取值见 `TitleTranslationSource`。存成字符串：遇到不认识的值也不会让整个队列读不出来。
    var translatedTitleSource: String? = nil
    /// 用户改的名字，只由重命名写。有它时元数据和翻译都不覆盖。
    var customTitle: String? = nil
    /// 推文全文，只有 X 视频有。
    var postText: String? = nil

    /// 不可变原文和首次译文；subtitleFilePath 始终是当前活动版本。
    var originalSubtitlePath: String? = nil
    var initialSubtitlePath: String? = nil
    var subtitleRevision: Int? = nil
    var translationSource: String? = nil
    var initialTranslationSource: String? = nil
    /// 首次登记时已存在、下载器落下及后来已接入的全部字幕路径，防止重扫旧轨抢活动版本。
    var knownSubtitlePaths: [String]? = nil
    /// 旧下载轨查来源失败的累计次数；每次启动最多一次，三次后按人工保守处理。
    var subtitleMetadataFailureCount: Int? = nil
    var transcriptionState: String? = nil
    var transcriptionError: String? = nil
    var transcriptionErrorCode: String? = nil
    var transcriptionAutomaticRetryCount: Int? = nil
    var transcriptionLanguage: String? = nil
    var transcriptionLanguageFallback: Bool? = nil

    var translationPolishable: Bool {
        let initialSource = initialTranslationSource ?? translationSource
        return initialSource == "apple" || initialSource == "youtube_auto"
    }

    /// 待播清单状态：MCP、列表界面和看板都读这一个属性，规则见 `WatchStatus.resolve`。
    var status: WatchStatus {
        WatchStatus.resolve(
            manual: watchStatus,
            watchedAt: watchedAt,
            playbackPosition: playbackPosition,
            inInbox: inInbox,
            hasPlayedThreeSeconds: hasPlayedThreeSeconds
        )
    }

    var statusIsManual: Bool { watchStatus.flatMap(WatchStatus.init(rawValue:)) != nil }

    /// 已看完或已归档：列表界面放进「已看」分组。
    var isWatched: Bool { !status.isInQueue }

    /// 右栏目录和进度条显示的章节：用户改过的、agent 写的、视频自带的，取第一组非空的。
    var availableChapters: [VideoChapter] { chapterSelection.chapters }

    var chapterSource: ChapterSource { chapterSelection.source }

    private var chapterSelection: (source: ChapterSource, chapters: [VideoChapter]) {
        if let userChapters { return (.user, userChapters) }
        if let agentChapters, !agentChapters.isEmpty { return (.agent, agentChapters) }
        if let chapters, !chapters.isEmpty { return (.video, chapters) }
        return (.none, [])
    }

    var hasUserChapters: Bool { userChapters != nil }

    /// 已看完满 `days` 天：状态是已看完，`watchedAt` 早于 `now` 往前 `days` 天。看板的「归档 N 条」用它。
    func isWatched(forAtLeastDays days: Int, now: Date = Date()) -> Bool {
        guard status == .watched, let watchedAt else { return false }
        return now.timeIntervalSince(watchedAt) >= Double(days) * 24 * 60 * 60
    }

    /// 手动挪到待看的条目又被播放满 3 秒：回到自动推算，按规则进观看中。其他手动状态不受播放影响。
    mutating func notePlayedThreeSeconds() {
        hasPlayedThreeSeconds = true
        guard watchStatus == WatchStatus.toWatch.rawValue, playbackPosition != nil else { return }
        watchStatus = nil
    }

    /// 用户或 agent 手动挪到某个状态。
    mutating func applyManualStatus(_ target: WatchStatus, now: Date = Date()) {
        switch target {
        case .watched:
            if watchedAt == nil { watchedAt = now }
            playbackPosition = nil
        case .archived:
            break
        case .inbox, .toWatch, .watching:
            watchedAt = nil
        }
        watchStatus = target.rawValue
        inInbox = nil
    }

    /// 详情侧栏是否有可展示内容：章节列表或本地字幕文件（歌词轴）。
    var hasSidePaneContent: Bool {
        !availableChapters.isEmpty || subtitleFileURL != nil
    }

    var resumablePosition: Double {
        let position = max(0, playbackPosition ?? 0)
        guard position >= 3 else { return 0 }
        if let duration, duration > 0, position >= duration - 10 { return 0 }
        return position
    }

    var sourceName: String {
        guard var host = URL(string: urlString)?.host?.lowercased() else { return "视频" }
        if host.contains("youtu") { return "YouTube" }
        if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter") { return "X" }
        if host.contains("bilibili") || host == "b23.tv" || host.hasSuffix(".b23.tv") { return "哔哩哔哩" }
        if host.contains("xiaohongshu") || host.contains("xhslink") { return "小红书" }
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        guard let first = label.first else { return "视频" }
        return String(first).uppercased() + label.dropFirst()
    }

    var localFileURL: URL? {
        guard let localFilePath else { return nil }
        let url = URL(fileURLWithPath: localFilePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var thumbnailFileURL: URL? {
        guard let thumbnailFilePath, !thumbnailFilePath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: thumbnailFilePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var subtitleFileURL: URL? {
        guard let subtitleFilePath, !subtitleFilePath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: subtitleFilePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// 待播清单的五个状态。英文值同时用在 queue.json 和 MCP 参数里。
enum WatchStatus: String, CaseIterable {
    case inbox
    case toWatch = "to_watch"
    case watching
    case watched
    case archived

    var displayName: String {
        switch self {
        case .inbox: return "收件箱"
        case .toWatch: return "待看"
        case .watching: return "观看中"
        case .watched: return "已看完"
        case .archived: return "已归档"
        }
    }

    /// 收件箱、待看、观看中在待播清单里；已看完、已归档在「已看」分组。
    var isInQueue: Bool {
        switch self {
        case .inbox, .toWatch, .watching: return true
        case .watched, .archived: return false
        }
    }

    /// 推算规则：手动定的优先；否则有 watchedAt 的已看完，有观看进度的观看中，新加入的收件箱，其余待看。
    /// 新条目只认真实播放标记；旧条目没有标记，保持原来的进度推算。
    static func resolve(manual: String?, watchedAt: Date?, playbackPosition: Double?, inInbox: Bool?, hasPlayedThreeSeconds: Bool? = nil) -> WatchStatus {
        if let manual, let status = WatchStatus(rawValue: manual) { return status }
        if watchedAt != nil { return .watched }
        if hasPlayedThreeSeconds == true { return .watching }
        if hasPlayedThreeSeconds == nil, playbackPosition != nil { return .watching }
        if inInbox == true { return .inbox }
        return .toWatch
    }
}

/// 播放器明确发送的事件，暂停和跳转立即终止当前连续播放片段。
enum WatchPlaybackEvent {
    case started(at: Double)
    case paused
    case seeked
}

/// 右栏目录现在显示的是哪一组章节。
enum ChapterSource: String {
    case user
    case agent
    case video
    case none
}

enum QueueOrderPolicy {
    static let currentVersion = 1
    static let versionDefaultsKey = "queueOrderVersion"

    static func newestFirst(_ items: [WatchItem]) -> [WatchItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.addedAt == rhs.element.addedAt {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.addedAt > rhs.element.addedAt
            }
            .map(\.element)
    }
}
