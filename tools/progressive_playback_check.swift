import Foundation

/// 边下边播的两条纯规则：当前该播哪个源；从预览换成本地文件时从哪里接着播。
/// 旧代码没有这两条规则，本检查在旧代码上编译即失败。
@main
struct ProgressivePlaybackCheck {
    private static let preview = URL(string: "https://rr1---sn-fixture.googlevideo.com/videoplayback?itag=18")!
    private static let local = URL(fileURLWithPath: "/tmp/9D0A346E-068C-41CE-B3FC-938A773AADC9.mp4")

    static func main() {
        checkSourceChoice()
        checkLocalFileLookup()
        checkHandoffPlan()
        checkHandoffReporting()
        print("progressive_playback_check=passed")
    }

    private static func checkSourceChoice() {
        typealias Decision = PlayerReadyDecision
        precondition(
            Decision.source(state: .downloading, previewURL: preview, localFileURL: nil) == .preview(preview),
            "下载中拿到预览流时，右侧播预览"
        )
        precondition(
            Decision.source(state: .downloading, previewURL: nil, localFileURL: nil) == .none,
            "下载中还没有预览流时，右侧显示等待画面"
        )
        precondition(
            Decision.source(state: .queued, previewURL: preview, localFileURL: nil) == .preview(preview),
            "重试倒计时、等网络、低电量暂停时，预览继续"
        )
        precondition(
            Decision.source(state: .queued, previewURL: nil, localFileURL: nil) == .none,
            "排队中没有预览流时显示等待画面"
        )
        precondition(
            Decision.source(state: .ready, previewURL: nil, localFileURL: local) == .localFile(local),
            "下完播本地文件"
        )
        precondition(
            Decision.source(state: .ready, previewURL: preview, localFileURL: local) == .localFile(local),
            "下完时即使预览还在，也换成本地文件"
        )
        precondition(
            Decision.source(state: .ready, previewURL: preview, localFileURL: nil) == .none,
            "下完但本地文件不在时不播"
        )
        precondition(
            Decision.source(state: .failed, previewURL: preview, localFileURL: local) == .none,
            "下载失败时不播预览，显示失败画面和重试按钮"
        )

        precondition(Decision.Source.preview(preview).url == preview, "预览源带出预览地址")
        precondition(Decision.Source.localFile(local).url == local, "本地源带出文件地址")
        precondition(Decision.Source.none.url == nil, "无源没有地址")
        precondition(Decision.Source.preview(preview).isPreview, "预览源算预览")
        precondition(!Decision.Source.localFile(local).isPreview, "本地文件不算预览")
        precondition(!Decision.Source.none.isPreview, "无源不算预览")
    }

    /// 队列每一行的 body 都会问一次「能不能播预览」，没下完时不能去查磁盘。
    private static func checkLocalFileLookup() {
        var lookups = 0
        func lookUpLocalFile() -> URL? {
            lookups += 1
            return local
        }
        _ = PlayerReadyDecision.source(state: .downloading, previewURL: preview, localFileURL: lookUpLocalFile())
        _ = PlayerReadyDecision.source(state: .queued, previewURL: nil, localFileURL: lookUpLocalFile())
        _ = PlayerReadyDecision.source(state: .failed, previewURL: preview, localFileURL: lookUpLocalFile())
        precondition(lookups == 0, "没下完时不得查本地文件")
        _ = PlayerReadyDecision.source(state: .ready, previewURL: nil, localFileURL: lookUpLocalFile())
        precondition(lookups == 1, "下完时才查本地文件")
    }

    private static func checkHandoffPlan() {
        typealias Handoff = PlaybackHandoffPolicy
        precondition(
            Handoff.plan(playerTime: 75.4, pendingSeekTime: nil, pendingResumeTime: nil, isPaused: false, reachedEnd: false)
                == Handoff.Plan(time: 75.4, shouldPlay: true),
            "正在播：本地文件从同一时刻接着播"
        )
        precondition(
            Handoff.plan(playerTime: 75.4, pendingSeekTime: nil, pendingResumeTime: nil, isPaused: true, reachedEnd: false)
                == Handoff.Plan(time: 75.4, shouldPlay: false),
            "暂停中：本地文件停在同一时刻，不擅自开播"
        )
        precondition(
            Handoff.plan(playerTime: 75.4, pendingSeekTime: 120, pendingResumeTime: nil, isPaused: false, reachedEnd: false).time == 120,
            "跳转还没完成：用跳转目标，不用跳转前的时间"
        )
        precondition(
            Handoff.plan(playerTime: .nan, pendingSeekTime: nil, pendingResumeTime: 30, isPaused: true, reachedEnd: false).time == 30,
            "续播跳转还没完成、播放器时间不可用：用续播位置"
        )
        precondition(
            Handoff.plan(playerTime: 4, pendingSeekTime: nil, pendingResumeTime: 30, isPaused: true, reachedEnd: false).time == 30,
            "续播跳转还没完成：用续播位置，不用跳转前的时间"
        )
        precondition(
            Handoff.plan(playerTime: .nan, pendingSeekTime: nil, pendingResumeTime: nil, isPaused: true, reachedEnd: false).time == 0,
            "时间都不可用：从 0 开始"
        )
        precondition(
            Handoff.plan(playerTime: -2, pendingSeekTime: nil, pendingResumeTime: nil, isPaused: false, reachedEnd: false).time == 0,
            "负数时间按 0 处理"
        )
        precondition(
            !Handoff.plan(playerTime: 600, pendingSeekTime: nil, pendingResumeTime: nil, isPaused: false, reachedEnd: true).shouldPlay,
            "预览已经播到结尾：换源后不再开播"
        )
    }

    private static func checkHandoffReporting() {
        typealias Handoff = PlaybackHandoffPolicy
        precondition(
            Handoff.reportedTime(handoffTarget: 75.4, playerTime: 0) == 75.4,
            "换源进行中上报目标时间，不报新片段的 0 秒（否则续播位置会被存成空、时间显示跳回 0:00）"
        )
        precondition(
            Handoff.reportedTime(handoffTarget: nil, playerTime: 12.5) == 12.5,
            "没有换源时上报播放器时间"
        )

        precondition(
            !Handoff.shouldHandOff(currentURL: nil, newURL: local, hasPlayer: false),
            "第一次载入走原来的载入流程"
        )
        precondition(
            Handoff.shouldHandOff(currentURL: preview, newURL: local, hasPlayer: true),
            "预览换成本地文件：在同一个播放器里换片段"
        )
        precondition(
            !Handoff.shouldHandOff(currentURL: local, newURL: local, hasPlayer: true),
            "地址没变不换"
        )
        precondition(
            !Handoff.shouldHandOff(currentURL: preview, newURL: local, hasPlayer: false),
            "播放器已经不在：走原来的载入流程"
        )
    }
}
