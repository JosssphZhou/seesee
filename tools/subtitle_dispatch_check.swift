import Foundation

@main
struct SubtitleDispatchCheck {
    static func main() {
        let primary = SubtitleDispatchPolicy.destination(
            isFloatingActive: false,
            isFullscreen: false
        )
        precondition(primary == .primary)
        precondition(SubtitleDispatchPolicy.shouldReceive(.primary, destination: primary))
        precondition(!SubtitleDispatchPolicy.shouldReceive(.fullscreen, destination: primary))
        precondition(!SubtitleDispatchPolicy.shouldReceive(.floating, destination: primary))

        let floating = SubtitleDispatchPolicy.destination(
            isFloatingActive: true,
            isFullscreen: false
        )
        precondition(floating == .floating)
        precondition(
            !SubtitleDispatchPolicy.shouldReceive(.primary, destination: floating),
            "悬浮期间主窗不得接收字幕更新"
        )
        precondition(
            !SubtitleDispatchPolicy.shouldReceive(.fullscreen, destination: floating),
            "悬浮期间全屏面也不得残留字幕"
        )
        precondition(SubtitleDispatchPolicy.shouldReceive(.floating, destination: floating))

        let restored = SubtitleDispatchPolicy.destination(
            isFloatingActive: false,
            isFullscreen: false
        )
        precondition(restored == .primary)
        precondition(
            SubtitleDispatchPolicy.shouldReceive(.primary, destination: restored),
            "点悬浮窗回到主窗后，主窗必须重新接收字幕"
        )
        precondition(
            !SubtitleDispatchPolicy.shouldReceive(.floating, destination: restored),
            "回到主窗后悬浮面不得继续接收字幕"
        )

        let fullscreen = SubtitleDispatchPolicy.destination(
            isFloatingActive: false,
            isFullscreen: true
        )
        precondition(fullscreen == .fullscreen)
        precondition(!SubtitleDispatchPolicy.shouldReceive(.primary, destination: fullscreen))
        precondition(SubtitleDispatchPolicy.shouldReceive(.fullscreen, destination: fullscreen))
        precondition(!SubtitleDispatchPolicy.shouldReceive(.floating, destination: fullscreen))

        let floatingOverFullscreen = SubtitleDispatchPolicy.destination(
            isFloatingActive: true,
            isFullscreen: true
        )
        precondition(
            floatingOverFullscreen == .floating,
            "切走应用时画面在悬浮窗，即使此前处于全屏"
        )
        precondition(
            !SubtitleDispatchPolicy.shouldReceive(.fullscreen, destination: floatingOverFullscreen)
        )

        precondition(
            SubtitleDispatchPolicy.presentationTime(afterSeekTo: 42, playerTime: 3) == 42,
            "暂停态 seek 必须按目标时间立刻重发，不得沿用尚未更新的播放器时钟"
        )
        precondition(SubtitleDispatchPolicy.presentationTime(afterSeekTo: 0, playerTime: 10) == 0)
        precondition(
            SubtitleDispatchPolicy.presentationTime(afterSeekTo: .nan, playerTime: 8) == 8,
            "目标时间无效时回落到播放器时钟"
        )
        precondition(SubtitleDispatchPolicy.presentationTime(afterSeekTo: -5, playerTime: 1) == 0)
        precondition(
            SubtitleDispatchPolicy.presentationTime(afterSeekTo: .nan, playerTime: .nan) == 0
        )
        precondition(
            SubtitleDispatchPolicy.visibleTime(pendingSeekTime: 42, playerTime: 3) == 42,
            "seek 尚未完成时必须继续按目标时间呈现，避免 SwiftUI 刷新把字幕写回旧句"
        )
        precondition(SubtitleDispatchPolicy.visibleTime(pendingSeekTime: nil, playerTime: 3) == 3)
        precondition(SubtitleDispatchPolicy.visibleTime(pendingSeekTime: .nan, playerTime: 3) == 3)

        precondition(
            !SubtitleSeekSession.shouldCommit(callbackID: 1, latestID: 2, finished: false),
            "被取消的旧回调不得提交"
        )
        precondition(
            !SubtitleSeekSession.shouldCommit(callbackID: 1, latestID: 2, finished: true),
            "过期回调即使 finished 为真也不得提交"
        )
        precondition(
            !SubtitleSeekSession.shouldCommit(callbackID: 2, latestID: 2, finished: false),
            "最新请求被取消时也不得提交"
        )
        precondition(SubtitleSeekSession.shouldCommit(callbackID: 2, latestID: 2, finished: true))

        var lateOld = SubtitleSeekSession()
        let cueA = lateOld.issue(time: 10)
        let cueB = lateOld.issue(time: 20)
        precondition(lateOld.pendingTime == 20)
        precondition(
            SubtitleDispatchPolicy.visibleTime(pendingSeekTime: lateOld.pendingTime, playerTime: 3) == 20
        )
        precondition(
            lateOld.complete(id: cueA, finished: false) == nil,
            "旧回调后到且 finished=NO 时必须丢弃，不得清掉 B 的待定时间"
        )
        precondition(lateOld.pendingTime == 20, "旧回调不得把待定时间改回 A")
        precondition(lateOld.complete(id: cueB, finished: true) == 20)
        precondition(lateOld.pendingTime == nil)

        var outOfOrder = SubtitleSeekSession()
        let first = outOfOrder.issue(time: 10)
        let second = outOfOrder.issue(time: 20)
        precondition(outOfOrder.complete(id: second, finished: true) == 20)
        precondition(outOfOrder.pendingTime == nil)
        precondition(
            outOfOrder.complete(id: first, finished: true) == nil,
            "乱序完成时后到的 A 回调不得覆盖已生效的 B"
        )
        precondition(outOfOrder.pendingTime == nil)

        var cancelledLatest = SubtitleSeekSession()
        _ = cancelledLatest.issue(time: 10)
        let replacement = cancelledLatest.issue(time: 20)
        cancelledLatest.invalidate()
        precondition(
            cancelledLatest.complete(id: replacement, finished: true) == nil,
            "换片或停止后，进行中的 seek 回调必须作废"
        )
        precondition(cancelledLatest.pendingTime == nil)

        let codez = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(
                startTime: 96.475,
                endTime: 98.356,
                text: "No worries. Okay, take your time\n没关系。好的，慢慢来"
            ),
            VideoSubtitleCue(
                startTime: 98.356,
                endTime: 100.137,
                text: "There's always tech, tech, tech trouble\n总是有技术问题"
            ),
            VideoSubtitleCue(
                startTime: 112.325,
                endTime: 113.726,
                text: "exciting to to get a chance to chat\n令人兴奋，能有机会和她聊天"
            ),
            VideoSubtitleCue(
                startTime: 113.766,
                endTime: 114.766,
                text: "with her\n和她"
            )
        ])

        func truncatedByTimescale(_ seconds: Double) -> Double {
            Double(Int64(seconds * Double(SubtitleDispatchPolicy.seekTimescale)))
                / Double(SubtitleDispatchPolicy.seekTimescale)
        }

        func textAfterSeekConversion(_ requested: Double) -> String? {
            VideoSubtitlePresentation.resolve(
                track: codez,
                isEnabled: true,
                at: SubtitleDispatchPolicy.quantizedSeekTime(requested)
            )?.text
        }

        precondition(truncatedByTimescale(98.356) == 98.355)
        precondition(truncatedByTimescale(113.766) == 113.765)
        precondition(
            VideoSubtitlePresentation.resolve(track: codez, isEnabled: true, at: 98.355)?.text
                == "No worries. Okay, take your time\n没关系。好的，慢慢来",
            "自然播放到句首前 1ms 必须仍是上一句，向句内取整不得变成全局前向容差"
        )
        precondition(
            VideoSubtitlePresentation.resolve(track: codez, isEnabled: true, at: 113.765)?.text
                == "exciting to to get a chance to chat\n令人兴奋，能有机会和她聊天",
            "句间短空隙的 hold-over 仍属上一句；截断时钟不得靠解析容差吞掉它"
        )
        precondition(
            textAfterSeekConversion(98.356)
                == "There's always tech, tech, tech trouble\n总是有技术问题",
            "98.356 经 600 时间基换算后必须解析到目标句，实际：\(textAfterSeekConversion(98.356) ?? "nil")"
        )
        precondition(
            textAfterSeekConversion(113.766) == "with her\n和她",
            "113.766 经 600 时间基换算后必须解析到目标句，实际：\(textAfterSeekConversion(113.766) ?? "nil")"
        )
        precondition(SubtitleDispatchPolicy.quantizedSeekTime(98.356) >= 98.356)
        precondition(SubtitleDispatchPolicy.quantizedSeekTime(113.766) >= 113.766)

        print("subtitle_dispatch_check=passed")
    }
}
