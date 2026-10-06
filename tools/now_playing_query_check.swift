import Foundation

/// 「正在看的位置」结果构造：位置只取播放器时间、字幕窗口夹取、双语拆行、没有播放器时的回答、取帧超时。
@main
struct NowPlayingQueryCheck {
    static func main() {
        checkPositionComesFromPlayerNotQueue()
        checkNotPlayingWithoutPlayerOrEntry()
        checkPlayerFileMustMatchEntry()
        checkNowPlayingFields()
        checkWindowClamping()
        checkSubtitleWindowAndOrder()
        checkBilingualSplit()
        checkCurrentCueFollowsOverlayHold()
        checkNoSubtitleTrack()
        checkFrameAnswers()
        checkFrameCaptureTimeout()
        print("now_playing_query_check=passed")
    }

    // MARK: - 夹具

    private static let fileURL = URL(fileURLWithPath: "/tmp/now-playing-check/video.mp4")

    private static func item(
        playbackPosition: Double? = nil,
        urlString: String = "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        duration: Double? = 600
    ) -> WatchItem {
        WatchItem(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            urlString: urlString,
            title: "测试视频",
            author: "测试作者",
            duration: duration,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            watchedAt: nil,
            state: .ready,
            progress: 1,
            progressLabel: "已下载",
            localFilePath: fileURL.path,
            errorMessage: nil,
            playbackPosition: playbackPosition,
            chapters: nil,
            thumbnailFilePath: nil,
            subtitleFilePath: nil
        )
    }

    private static let track = VideoSubtitleTrack(cues: [
        VideoSubtitleCue(startTime: 10, endTime: 12, text: "early\n早"),
        VideoSubtitleCue(startTime: 40, endTime: 43, text: "Hello world\n你好世界"),
        VideoSubtitleCue(startTime: 43.5, endTime: 46, text: "Only English"),
        VideoSubtitleCue(startTime: 70, endTime: 72, text: "later\n稍后"),
        VideoSubtitleCue(startTime: 100, endTime: 103, text: "queue position\n队列位置"),
        VideoSubtitleCue(startTime: 700, endTime: 702, text: "far\n很远")
    ])

    private static func context(
        position: Double,
        playbackPosition: Double? = nil,
        isPlaying: Bool = true,
        rate: Double = 1.5,
        duration: Double? = 612.3,
        track: VideoSubtitleTrack? = track,
        urlString: String = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    ) -> NowPlayingContext? {
        NowPlayingQuery.context(
            entry: NowPlayingEntry(
                item: item(playbackPosition: playbackPosition, urlString: urlString),
                fileURL: fileURL,
                subtitleTrack: track
            ),
            playerFileURL: fileURL,
            clock: NowPlayingClock(
                seconds: position,
                isPlaying: isPlaying,
                rate: rate,
                durationSeconds: duration
            )
        )
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    // MARK: - 检查

    private static func checkPositionComesFromPlayerNotQueue() {
        let ctx = context(position: 42, playbackPosition: 100)
        precondition(ctx != nil, "登记条目与播放器同时存在时必须有上下文")
        let result = NowPlayingQuery.nowPlaying(ctx)
        precondition(double(result["positionSeconds"]) == 42, "位置必须取播放器时间 42，不能取 queue.json 的 100：\(result)")
        precondition(result["position"] as? String == "0:42", "位置文字必须是 0:42：\(result)")

        let subtitles = NowPlayingQuery.subtitles(ctx, before: 0, after: 0)
        precondition(double(subtitles["positionSeconds"]) == 42, "字幕查询的位置同样取播放器时间：\(subtitles)")
        let current = subtitles["current"] as? [String: Any]
        precondition(current?["original"] as? String == "Hello world", "当前字幕必须是 42 秒处那句，不是 100 秒处：\(subtitles)")
    }

    private static func checkNotPlayingWithoutPlayerOrEntry() {
        let entry = NowPlayingEntry(item: item(), fileURL: fileURL, subtitleTrack: track)
        let clock = NowPlayingClock(seconds: 5, isPlaying: true, rate: 1, durationSeconds: 10)
        precondition(NowPlayingQuery.context(entry: entry, playerFileURL: nil, clock: nil) == nil, "没有播放器时没有上下文")
        precondition(NowPlayingQuery.context(entry: nil, playerFileURL: fileURL, clock: clock) == nil, "没有登记条目时没有上下文")
        let badClock = NowPlayingClock(seconds: .nan, isPlaying: true, rate: 1, durationSeconds: 10)
        precondition(NowPlayingQuery.context(entry: entry, playerFileURL: fileURL, clock: badClock) == nil, "播放器时间无效时不编造位置")

        let result = NowPlayingQuery.nowPlaying(nil)
        assertNoVideo(result, "now_playing")
        precondition(result["message"] as? String == "没有在播放", "没有在播放：中文说明")
        precondition(result["positionSeconds"] == nil, "没有在播放时不返回位置")

        let subtitles = NowPlayingQuery.subtitles(nil, before: 30, after: 30)
        assertNoVideo(subtitles, "字幕")
        precondition(subtitles["message"] as? String == "没有在播放", "字幕查询同样回答没有在播放")
        precondition(subtitles["cues"] == nil, "没有在播放时不返回字幕")
    }

    /// 没有视频打开：三个状态字段固定为 false、false、none。
    private static func assertNoVideo(_ result: [String: Any], _ label: String) {
        assertPlayback(result, videoOpen: false, playing: false, state: "none", "\(label) 没有视频")
    }

    /// `playing` 只在真的在播放时为 true；`videoOpen` 表示有视频打开。
    private static func assertPlayback(_ result: [String: Any], videoOpen: Bool, playing: Bool, state: String, _ label: String) {
        precondition(result["videoOpen"] as? Bool == videoOpen, "\(label)：videoOpen 应为 \(videoOpen)：\(result)")
        precondition(result["playing"] as? Bool == playing, "\(label)：playing 应为 \(playing)：\(result)")
        precondition(result["state"] as? String == state, "\(label)：state 应为 \(state)：\(result)")
    }

    private static func checkPlayerFileMustMatchEntry() {
        let entry = NowPlayingEntry(item: item(), fileURL: fileURL, subtitleTrack: track)
        let clock = NowPlayingClock(seconds: 5, isPlaying: true, rate: 1, durationSeconds: 10)
        let other = URL(fileURLWithPath: "/tmp/now-playing-check/other.mp4")
        precondition(
            NowPlayingQuery.context(entry: entry, playerFileURL: other, clock: clock) == nil,
            "播放器放的不是登记条目的文件时，不能把别的条目的标题安到这个位置上"
        )
        let sameButUnstandardized = URL(fileURLWithPath: "/tmp/now-playing-check/./video.mp4")
        precondition(
            NowPlayingQuery.context(entry: entry, playerFileURL: sameButUnstandardized, clock: clock) != nil,
            "同一文件的不同写法视为同一文件"
        )
    }

    private static func checkNowPlayingFields() {
        let result = NowPlayingQuery.nowPlaying(context(position: 123.456, isPlaying: false, rate: 1.5))
        assertPlayback(result, videoOpen: true, playing: false, state: "paused", "now_playing 暂停")
        precondition(result["title"] as? String == "测试视频" && result["author"] as? String == "测试作者", "标题作者：\(result)")
        precondition(result["sourceURL"] as? String == "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "来源链接：\(result)")
        precondition(result["videoID"] as? String == "dQw4w9WgXcQ", "YouTube 视频编号：\(result)")
        precondition(result["itemID"] as? String == "11111111-2222-3333-4444-555555555555", "条目编号：\(result)")
        precondition(double(result["positionSeconds"]) == 123.46, "位置保留两位小数：\(result)")
        precondition(result["position"] as? String == "2:03", "位置文字：\(result)")
        precondition(double(result["durationSeconds"]) == 612.3, "时长优先取播放器：\(result)")
        precondition(result["duration"] as? String == "10:12", "时长文字：\(result)")
        precondition(double(result["rate"]) == 1.5, "倍速：\(result)")

        let playing = NowPlayingQuery.nowPlaying(context(position: 1, isPlaying: true))
        assertPlayback(playing, videoOpen: true, playing: true, state: "playing", "now_playing 播放中")

        let noDuration = NowPlayingQuery.nowPlaying(context(position: 1, duration: nil))
        precondition(double(noDuration["durationSeconds"]) == 600, "播放器没有时长时退回条目时长：\(noDuration)")

        let local = NowPlayingQuery.nowPlaying(context(position: 1, urlString: "file:///Users/x/a.mp4"))
        precondition(local["sourceURL"] is NSNull, "非网页来源的链接为 null：\(local)")
        precondition(local["videoID"] is NSNull, "取不到视频编号为 null：\(local)")
        precondition(NowPlayingQuery.jsonText(local).contains("\"videoID\":null"), "null 字段必须出现在 JSON 里")
    }

    private static func checkWindowClamping() {
        precondition(NowPlayingQuery.clampedWindow(nil) == 30, "前后窗口默认 30 秒")
        precondition(NowPlayingQuery.clampedWindow(-5) == 0, "窗口下限 0")
        precondition(NowPlayingQuery.clampedWindow(1000) == 600, "窗口上限 600")
        precondition(NowPlayingQuery.clampedWindow(12.5) == 12.5, "范围内原样")
        precondition(NowPlayingQuery.clampedWindow("abc") == 30, "不是数字用默认")
        precondition(NowPlayingQuery.clampedWindow(Double.nan) == 30, "NaN 用默认")
        precondition(NowPlayingQuery.clampedWindow(NSNumber(value: 45)) == 45, "JSON 解出的整数可用")
        precondition(NowPlayingQuery.clampedFrameWidth(nil) == 1024, "画面宽默认 1024")
        precondition(NowPlayingQuery.clampedFrameWidth(100) == 320, "画面宽下限 320")
        precondition(NowPlayingQuery.clampedFrameWidth(5000) == 1920, "画面宽上限 1920")
        precondition(NowPlayingQuery.clampedFrameWidth(800) == 800, "画面宽范围内原样")

        // 结果构造本身也夹取，桥接之外的调用方传错也不越界。
        let wide = NowPlayingQuery.subtitles(context(position: 100), before: 99_999, after: -3)
        let cues = wide["cues"] as? [[String: Any]] ?? []
        precondition(cues.count == 5, "before 夹到 600、after 夹到 0：[0,100] 内五条：\(cues.count)")
        precondition(double(wide["beforeSeconds"]) == 600 && double(wide["afterSeconds"]) == 0, "结果写明实际窗口：\(wide)")
    }

    private static func checkSubtitleWindowAndOrder() {
        let result = NowPlayingQuery.subtitles(context(position: 42), before: 30, after: 30)
        assertPlayback(result, videoOpen: true, playing: true, state: "playing", "字幕播放中")
        precondition(result["hasSubtitles"] as? Bool == true, "有字幕：\(result)")
        let pausedSubtitles = NowPlayingQuery.subtitles(context(position: 42, isPlaying: false), before: 30, after: 30)
        assertPlayback(pausedSubtitles, videoOpen: true, playing: false, state: "paused", "字幕暂停")
        let cues = result["cues"] as? [[String: Any]] ?? []
        let starts = cues.compactMap { double($0["start"]) }
        precondition(starts == [10, 40, 43.5, 70], "窗口 [12,72] 内按开始时间排序，恰好在 12 秒结束的那条算在窗口内：\(starts)")
        let hello = cues.first { double($0["start"]) == 40 } ?? [:]
        precondition(hello["startText"] as? String == "0:40", "开始时间文字：\(hello)")
        precondition(double(hello["end"]) == 43, "结束时间：\(hello)")

        // 前后不对称：[13,69]，12 秒结束和 70 秒开始的都在窗口外。
        let edge = NowPlayingQuery.subtitles(context(position: 42), before: 29, after: 27)
        let edgeStarts = (edge["cues"] as? [[String: Any]] ?? []).compactMap { double($0["start"]) }
        precondition(edgeStarts == [40, 43.5], "前后窗口分别生效：\(edgeStarts)")
    }

    private static func checkBilingualSplit() {
        let result = NowPlayingQuery.subtitles(context(position: 41), before: 0, after: 5)
        let cues = result["cues"] as? [[String: Any]] ?? []
        let bilingual = cues.first { double($0["start"]) == 40 } ?? [:]
        precondition(bilingual["original"] as? String == "Hello world", "双语第一行是原文：\(bilingual)")
        precondition(bilingual["translation"] as? String == "你好世界", "双语第二行是译文：\(bilingual)")
        precondition(bilingual["text"] as? String == "Hello world\n你好世界", "text 保留两行：\(bilingual)")
        let mono = cues.first { double($0["start"]) == 43.5 } ?? [:]
        precondition(mono["original"] as? String == "Only English", "单语只有原文：\(mono)")
        precondition(mono["translation"] is NSNull, "单语译文为 null：\(mono)")

        let duplicated = NowPlayingQuery.cueObject(VideoSubtitleCue(startTime: 1, endTime: 2, text: "Same\nSame"))
        precondition(duplicated["translation"] is NSNull && duplicated["original"] as? String == "Same", "原文译文相同按显示规则折叠为一行：\(duplicated)")
    }

    private static func checkCurrentCueFollowsOverlayHold() {
        // 43 到 43.5 之间的空隙短于 1 秒，播放器浮层继续显示上一句；查询结果与屏幕一致。
        let hold = NowPlayingQuery.subtitles(context(position: 43.2), before: 0, after: 0)
        let current = hold["current"] as? [String: Any]
        precondition(double(current?["start"]) == 40, "短空隙里当前字幕是屏幕上还留着的上一句：\(hold)")

        let gap = NowPlayingQuery.subtitles(context(position: 55), before: 0, after: 0)
        precondition(gap["current"] is NSNull, "长空隙里没有当前字幕：\(gap)")
    }

    private static func checkNoSubtitleTrack() {
        let result = NowPlayingQuery.subtitles(context(position: 42, track: nil), before: 30, after: 30)
        assertPlayback(result, videoOpen: true, playing: true, state: "playing", "没有字幕轨")
        precondition(result["hasSubtitles"] as? Bool == false, "没有字幕轨：hasSubtitles 为 false")
        precondition((result["cues"] as? [Any])?.isEmpty == true, "没有字幕轨：cues 为空")
        precondition(result["current"] is NSNull, "没有字幕轨：current 为 null")
    }

    private static func checkFrameAnswers() {
        let request = AgentLinkRequest(token: "t", query: .frame, before: 30, after: 30, maxWidth: 800)
        var requestedWidth: Double?
        let ok = NowPlayingQuery.answer(request, context: context(position: 42)) { width in
            requestedWidth = width
            return .image("ZmFrZQ==")
        }
        guard case .success(let payload) = ok else { preconditionFailure("取帧成功应返回结果：\(ok)") }
        precondition(requestedWidth == 800, "按请求宽度取帧")
        precondition(payload["data"] as? String == "ZmFrZQ==" && payload["mimeType"] as? String == "image/jpeg", "画面数据：\(payload)")
        precondition(double(payload["positionSeconds"]) == 42 && payload["title"] as? String == "测试视频", "画面附位置和标题：\(payload)")
        precondition(double(payload["bytes"]) == 4, "写出 JPEG 实际字节数：\(payload)")
        assertPlayback(payload, videoOpen: true, playing: true, state: "playing", "画面播放中")
        guard case .success(let pausedFrame) = NowPlayingQuery.answer(request, context: context(position: 42, isPlaying: false), captureFrame: { _ in .image("ZmFrZQ==") }) else {
            preconditionFailure("暂停时取帧成功")
        }
        assertPlayback(pausedFrame, videoOpen: true, playing: false, state: "paused", "画面暂停")

        let timedOut = NowPlayingQuery.answer(request, context: context(position: 42)) { _ in .timedOut }
        guard case .failure(let code, let message) = timedOut else { preconditionFailure("超时必须是失败：\(timedOut)") }
        precondition(code == "frame_unavailable" && (message ?? "").contains("超时"), "超时：\(code) \(message ?? "")")

        let failed = NowPlayingQuery.answer(request, context: context(position: 42)) { _ in .failed }
        guard case .failure(let failedCode, _) = failed else { preconditionFailure("取帧失败必须是失败：\(failed)") }
        precondition(failedCode == "frame_unavailable", "取帧失败：\(failedCode)")

        var capturedWhileIdle = false
        let idle = NowPlayingQuery.answer(request, context: nil) { _ in
            capturedWhileIdle = true
            return .image("x")
        }
        guard case .success(let idlePayload) = idle else { preconditionFailure("没有在播放不是错误：\(idle)") }
        precondition(!capturedWhileIdle, "没有在播放时不取帧")
        assertNoVideo(idlePayload, "画面")
        precondition(idlePayload["data"] == nil, "没有在播放时不返回画面：\(idlePayload)")

        let nowRequest = AgentLinkRequest(token: "t", query: .nowPlaying, before: 30, after: 30, maxWidth: 1024)
        guard case .success(let now) = NowPlayingQuery.answer(nowRequest, context: context(position: 7), captureFrame: { _ in .failed }) else {
            preconditionFailure("now_playing 应成功")
        }
        precondition(double(now["positionSeconds"]) == 7, "answer 分派 now_playing：\(now)")
        let subRequest = AgentLinkRequest(token: "t", query: .subtitles, before: 1, after: 1, maxWidth: 1024)
        guard case .success(let sub) = NowPlayingQuery.answer(subRequest, context: context(position: 41), captureFrame: { _ in .failed }) else {
            preconditionFailure("subtitles 应成功")
        }
        precondition((sub["cues"] as? [Any])?.count == 1, "answer 分派 subtitles 并用请求窗口：\(sub)")
    }

    private static func checkFrameCaptureTimeout() {
        let start = Date()
        let outcome = NowPlayingFrameCapture.run(timeout: 0.2) {
            Thread.sleep(forTimeInterval: 1.5)
            return "late"
        }
        let elapsed = Date().timeIntervalSince(start)
        precondition(outcome == .timedOut, "超过时限必须返回超时：\(outcome)")
        precondition(elapsed < 1.0, "超时要按时返回，不等取帧做完：\(elapsed)")
        precondition(NowPlayingFrameCapture.run(timeout: 1) { nil } == .failed, "取帧返回空为失败")
        precondition(NowPlayingFrameCapture.run(timeout: 1) { "abc" } == .image("abc"), "按时取到画面")
    }
}
