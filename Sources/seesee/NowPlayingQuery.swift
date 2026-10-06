import Foundation

/// 视频详情视图登记的「正在看的条目」：条目、本地视频文件、已加载的字幕轨。
struct NowPlayingEntry: Equatable {
    let item: WatchItem
    let fileURL: URL
    let subtitleTrack: VideoSubtitleTrack?
}

/// 查询那一刻从活动播放器实时读到的状态。位置一律来自播放器 `currentTime()`。
struct NowPlayingClock: Equatable {
    let seconds: Double
    let isPlaying: Bool
    let rate: Double
    let durationSeconds: Double?
}

struct NowPlayingContext: Equatable {
    let entry: NowPlayingEntry
    let clock: NowPlayingClock
}

/// 取帧放到后台线程并设时限；超时立刻回答，不等取帧做完。
enum NowPlayingFrameCapture {
    enum Outcome: Equatable {
        case image(String)
        case failed
        case timedOut
    }

    static let timeout: TimeInterval = 5

    private final class ResultBox {
        private let lock = NSLock()
        private var value: String?
        func set(_ newValue: String?) {
            lock.lock(); value = newValue; lock.unlock()
        }
        func get() -> String? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    static func run(timeout: TimeInterval, _ work: @escaping () -> String?) -> Outcome {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(work())
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return .timedOut }
        return box.get().map(Outcome.image) ?? .failed
    }
}

/// 三种查询的结果构造：输入是登记信息、播放器时间、字幕轨，输出是可直接编码的 JSON 对象。
enum NowPlayingQuery {
    static let notPlayingMessage = "没有在播放"
    static let notRunningMessage = "seesee 没有运行"
    static let defaultSubtitleWindow: Double = 30
    static let subtitleWindowRange: ClosedRange<Double> = 0...600
    static let defaultFrameWidth: Double = 1024
    static let frameWidthRange: ClosedRange<Double> = 320...1920
    static let frameMimeType = "image/jpeg"

    static func clampedWindow(_ value: Any?) -> Double {
        clamp(value, fallback: defaultSubtitleWindow, range: subtitleWindowRange)
    }

    static func clampedFrameWidth(_ value: Any?) -> Double {
        clamp(value, fallback: defaultFrameWidth, range: frameWidthRange).rounded()
    }

    /// 登记条目、活动播放器和播放器时间齐全，且播放器放的正是登记条目的文件时才有上下文。
    static func context(
        entry: NowPlayingEntry?,
        playerFileURL: URL?,
        clock: NowPlayingClock?
    ) -> NowPlayingContext? {
        guard let entry, let playerFileURL, let clock, clock.seconds.isFinite else { return nil }
        guard entry.fileURL.standardizedFileURL.path == playerFileURL.standardizedFileURL.path else { return nil }
        return NowPlayingContext(entry: entry, clock: clock)
    }

    /// 三个查询共用的状态字段：`videoOpen` 表示有视频打开，`playing` 只在真的在播放时为 true。
    static func playbackFields(_ context: NowPlayingContext?) -> [String: Any] {
        guard let context else { return ["videoOpen": false, "playing": false, "state": "none"] }
        let isPlaying = context.clock.isPlaying
        return ["videoOpen": true, "playing": isPlaying, "state": isPlaying ? "playing" : "paused"]
    }

    static func notPlaying() -> [String: Any] {
        playbackFields(nil).merging(["message": notPlayingMessage]) { _, new in new }
    }

    static func notRunning() -> [String: Any] {
        playbackFields(nil).merging(["message": notRunningMessage]) { _, new in new }
    }

    static func nowPlaying(_ context: NowPlayingContext?) -> [String: Any] {
        guard let context else { return notPlaying() }
        let item = context.entry.item
        let position = max(0, context.clock.seconds)
        let duration = finitePositive(context.clock.durationSeconds) ?? finitePositive(item.duration)
        return playbackFields(context).merging(titleFields(item)) { _, new in new }.merging([
            "author": item.author,
            "sourceURL": webURL(item.urlString) ?? NSNull(),
            "videoID": YouTubeVideoID.extract(from: item.urlString) ?? NSNull(),
            "itemID": item.id.uuidString,
            "positionSeconds": rounded(position, places: 2),
            "position": timecode(position),
            "durationSeconds": duration.map { rounded($0, places: 2) } ?? NSNull(),
            "duration": duration.map(timecode) ?? NSNull(),
            "rate": rounded(context.clock.rate, places: 2)
        ]) { _, new in new }
    }

    /// 当前字幕与前后窗口内的字幕。当前那句与播放器浮层同一规则：短空隙里延续上一句。
    static func subtitles(_ context: NowPlayingContext?, before: Double, after: Double) -> [String: Any] {
        guard let context else { return notPlaying() }
        let before = clampedWindow(before)
        let after = clampedWindow(after)
        let position = max(0, context.clock.seconds)
        var result = playbackFields(context).merging([
            "positionSeconds": rounded(position, places: 2),
            "position": timecode(position),
            "beforeSeconds": before,
            "afterSeconds": after
        ]) { _, new in new }
        guard let track = context.entry.subtitleTrack, !track.cues.isEmpty else {
            result["hasSubtitles"] = false
            result["current"] = NSNull()
            result["cues"] = [[String: Any]]()
            return result
        }
        // cues(around:window:) 是对称窗口；把 [位置 - before, 位置 + after] 换成中心和半宽。
        let cues = track
            .cues(around: position + (after - before) / 2, window: (before + after) / 2)
            .sorted { ($0.startTime, $0.endTime) < ($1.startTime, $1.endTime) }
        let shown = VideoSubtitlePresentation.resolve(track: track, mode: .bilingual, at: position)
        let current = shown.flatMap { presentation in track.cues.first { $0.id == presentation.id } }
        result["hasSubtitles"] = true
        result["current"] = current.map(cueObject) ?? NSNull()
        result["cues"] = cues.map(cueObject)
        return result
    }

    /// 双语字幕按显示规则拆行：第一行是原文，其余是译文；只有一行时译文为 null。
    static func cueObject(_ cue: VideoSubtitleCue) -> [String: Any] {
        let lines = VideoSubtitlePresentation.displayLines(from: cue.text)
        return [
            "start": rounded(cue.startTime, places: 3),
            "end": rounded(cue.endTime, places: 3),
            "startText": timecode(cue.startTime),
            "text": lines.joined(separator: "\n"),
            "original": lines.first ?? "",
            "translation": lines.count >= 2 ? lines.dropFirst().joined(separator: "\n") : NSNull()
        ]
    }

    /// 标题各字段，不截断：`title` 是界面上显示的主标题（改名、中文译名、原标题依次取），
    /// 其余字段原样给出，没有时为 null。`translatedTitleSource` 是 author（作者提供）或 onDevice（本机翻译）。
    static func titleFields(_ item: WatchItem) -> [String: Any] {
        [
            "title": item.titleDisplay.primary,
            "originalTitle": item.resolvedOriginalTitle,
            "translatedTitle": item.translatedTitle ?? NSNull(),
            "translatedTitleSource": item.translatedTitleSource ?? NSNull(),
            "customTitle": item.customTitle ?? NSNull(),
            "postText": item.postText ?? NSNull()
        ]
    }

    /// 画面附带的说明：对应的时间和标题。
    static func frameCaption(_ context: NowPlayingContext) -> [String: Any] {
        let position = max(0, context.clock.seconds)
        return playbackFields(context).merging(titleFields(context.entry.item)) { _, new in new }.merging([
            "itemID": context.entry.item.id.uuidString,
            "positionSeconds": rounded(position, places: 2),
            "position": timecode(position)
        ]) { _, new in new }
    }

    /// 应用端回答一次套接字查询。`captureFrame` 只在有画面可取时被调用。
    static func answer(
        _ request: AgentLinkRequest,
        context: NowPlayingContext?,
        captureFrame: (Double) -> NowPlayingFrameCapture.Outcome
    ) -> AgentLinkReply {
        switch request.query {
        case .nowPlaying:
            return .success(nowPlaying(context))
        case .subtitles:
            return .success(subtitles(context, before: request.before, after: request.after))
        case .frame:
            guard let context else { return .success(notPlaying()) }
            let width = clampedFrameWidth(request.maxWidth)
            switch captureFrame(width) {
            case .image(let base64):
                var payload = frameCaption(context)
                payload["data"] = base64
                payload["mimeType"] = frameMimeType
                payload["bytes"] = Data(base64Encoded: base64)?.count ?? 0
                payload["maxWidth"] = width
                return .success(payload)
            case .timedOut:
                return .failure(
                    code: AgentLinkReply.frameUnavailable,
                    message: "取当前画面超时（超过 \(Int(NowPlayingFrameCapture.timeout)) 秒）"
                )
            case .failed:
                return .failure(code: AgentLinkReply.frameUnavailable, message: "没能从视频文件取到当前画面")
            }
        case .listQueue, .moveItems, .addLinks, .searchSubtitles, .seekTo, .writeChapters, .readSubtitles, .writeSubtitleTranslations, .restoreInitialTranslation:
            // 待播清单的查询由 QueueAgentProvider 回答，不会到这里。
            return .failure(code: AgentLinkReply.badRequest, message: nil)
        }
    }

    static func jsonText(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 小工具

    /// 与播放控制条同一取整规则。
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }

    private static func clamp(_ value: Any?, fallback: Double, range: ClosedRange<Double>) -> Double {
        // JSON 的 true/false 也能桥接成数字，先排除。
        if let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
            return fallback
        }
        let number: Double?
        switch value {
        case let double as Double:
            number = double
        case let int as Int:
            number = Double(int)
        case let value as NSNumber:
            number = value.doubleValue
        default:
            number = nil
        }
        guard let number, number.isFinite else { return fallback }
        return min(max(number, range.lowerBound), range.upperBound)
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func webURL(_ string: String) -> String? {
        guard let scheme = URL(string: string)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return string
    }
}
