import Foundation

@main
struct SubtitlePresentationCheck {
    static func main() {
        let bilingual = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "I've heard this before\n我以前听过"),
            VideoSubtitleCue(startTime: 2.4, endTime: 4, text: "Next sentence\n下一句")
        ])

        let bilingualPresentation = VideoSubtitlePresentation.resolve(
            track: bilingual,
            isEnabled: true,
            at: 1
        )
        precondition(bilingualPresentation?.text == "I've heard this before\n我以前听过")
        precondition(
            VideoSubtitlePresentation.displayLines(from: "I've heard this before\n我以前听过")
                == ["I've heard this before", "我以前听过"]
        )

        let identical = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "Sundar Pichai\nSundar Pichai")
        ])
        let identicalPresentation = VideoSubtitlePresentation.resolve(
            track: identical,
            isEnabled: true,
            at: 1
        )
        precondition(
            identicalPresentation?.text == "Sundar Pichai",
            "原文与译文相同时只显示一行，实际：\(identicalPresentation?.text ?? "nil")"
        )
        precondition(
            VideoSubtitlePresentation.displayLines(from: "Sundar Pichai\nSundar Pichai")
                == ["Sundar Pichai"]
        )
        precondition(
            VideoSubtitlePresentation.displayLines(from: "Hello\nHello\n你好") == ["Hello", "你好"]
        )

        let shortGapTrack = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "Hold me\n留着我"),
            VideoSubtitleCue(startTime: 2.5, endTime: 4, text: "Next\n下一句")
        ])
        let held = VideoSubtitlePresentation.resolve(
            track: shortGapTrack,
            isEnabled: true,
            at: 2.2
        )
        precondition(
            held?.text == "Hold me\n留着我",
            "句间空隙低于约一秒时应延续上一句，实际：\(held?.text ?? "nil")"
        )
        precondition(held?.id == shortGapTrack.cues[0].id)

        let longGapTrack = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "Fade out\n淡出"),
            VideoSubtitleCue(startTime: 4, endTime: 6, text: "Later\n之后")
        ])
        let faded = VideoSubtitlePresentation.resolve(
            track: longGapTrack,
            isEnabled: true,
            at: 3
        )
        precondition(
            faded == nil,
            "句间空隙超过约一秒时不得延续，实际：\(faded?.text ?? "nil")"
        )

        let afterLast = VideoSubtitlePresentation.resolve(
            track: shortGapTrack,
            isEnabled: true,
            at: 5
        )
        precondition(afterLast == nil, "最后一句结束后不得延续")

        precondition(
            VideoSubtitlePresentation.resolve(track: bilingual, isEnabled: false, at: 1) == nil
        )
        precondition(
            VideoSubtitlePresentation.resolve(track: nil, isEnabled: true, at: 1) == nil
        )

        let oneSecondGap = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 1, text: "Edge"),
            VideoSubtitleCue(startTime: 2, endTime: 3, text: "After")
        ])
        let atThreshold = VideoSubtitlePresentation.resolve(
            track: oneSecondGap,
            isEnabled: true,
            at: 1.4
        )
        precondition(
            atThreshold?.text == "Edge",
            "空隙刚好约一秒时仍应延续上一句，实际：\(atThreshold?.text ?? "nil")"
        )

        let codez = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(
                startTime: 9.486,
                endTime: 10.907,
                text: "Potato with spelled with an E\nPotato，E结尾的。"
            ),
            VideoSubtitleCue(
                startTime: 12.428,
                endTime: 13.729,
                text: "and I have been\n我在"
            ),
            VideoSubtitleCue(
                startTime: 14.330,
                endTime: 17.151,
                text: "at Cursor for about five months\nCursor工作了大约五个月。"
            )
        ])
        precondition(
            VideoSubtitlePresentation.resolve(track: codez, isEnabled: true, at: 12.5)?.text
                == "and I have been\n我在",
            "短句在自身时间窗内必须显示，去重不得折叠原文与译文"
        )
        precondition(
            VideoSubtitlePresentation.resolve(track: codez, isEnabled: true, at: 12.0) == nil,
            "0:12.0 落在上一句结束后超过约一秒的空隙，延续不得把短句提前显示，也不得误伤后续短句"
        )
        precondition(
            VideoSubtitlePresentation.resolve(track: codez, isEnabled: true, at: 13.9)?.text
                == "and I have been\n我在",
            "短句结束后 0.6 秒空隙应延续上一句"
        )
        precondition(
            VideoSubtitlePresentation.resolve(track: codez, isEnabled: true, at: 14.5)?.text
                == "at Cursor for about five months\nCursor工作了大约五个月。"
        )

        let first = VideoSubtitlePresentation.resolve(track: bilingual, isEnabled: true, at: 1)
        let second = VideoSubtitlePresentation.resolve(track: bilingual, isEnabled: true, at: 3)
        precondition(first != nil && second != nil)
        precondition(SubtitleOverlayChromeAnimation.resolve(from: nil, to: first) == .fadeIn)
        precondition(SubtitleOverlayChromeAnimation.resolve(from: first, to: nil) == .fadeOut)
        precondition(
            SubtitleOverlayChromeAnimation.resolve(from: first, to: second) == .replace,
            "句间换字不得淡入淡出整条浮层"
        )
        let heldShort = VideoSubtitlePresentation.resolve(track: codez, isEnabled: true, at: 13.9)
        let months = VideoSubtitlePresentation.resolve(track: codez, isEnabled: true, at: 14.5)
        precondition(
            SubtitleOverlayChromeAnimation.resolve(from: heldShort, to: months) == .replace,
            "延续句切到下一句时浮层应保持可见"
        )

        // 字幕三档：仅译文丢原文行；无译文的 cue 在仅译文档下不显示；关档一律无呈现；循环顺序固定。
        precondition(
            VideoSubtitlePresentation.resolve(track: bilingual, mode: .translationOnly, at: 1)?.text == "我以前听过"
        )
        precondition(
            VideoSubtitlePresentation.resolve(track: bilingual, mode: .bilingual, at: 1)?.text
                == "I've heard this before\n我以前听过"
        )
        precondition(VideoSubtitlePresentation.resolve(track: bilingual, mode: .off, at: 1) == nil)
        let sourceOnly = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "english only line")
        ])
        precondition(VideoSubtitlePresentation.resolve(track: sourceOnly, mode: .translationOnly, at: 1) == nil)
        precondition(VideoSubtitlePresentation.resolve(track: sourceOnly, mode: .bilingual, at: 1) != nil)
        // 中文原声视频：生成的字幕原文行与译文行相同。双语档折叠成一行，仅译文档也必须显示这一行，不能整段无字幕。
        let chineseSource = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "而是一套能理解代码库\n而是一套能理解代码库")
        ])
        precondition(
            VideoSubtitlePresentation.resolve(track: chineseSource, mode: .bilingual, at: 1)?.text == "而是一套能理解代码库",
            "原文与译文相同时双语档只显示一行"
        )
        precondition(
            VideoSubtitlePresentation.resolve(track: chineseSource, mode: .translationOnly, at: 1)?.text == "而是一套能理解代码库",
            "原文与译文相同时仅译文档仍应显示译文"
        )
        // 折叠后只剩一行：含汉字则视为译文并显示（中文原声单行、YouTube .zh-hans）；纯外文原文轨仍不显示。
        let singleChinese = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "而是一套能理解代码库")
        ])
        precondition(
            VideoSubtitlePresentation.resolve(track: singleChinese, mode: .translationOnly, at: 1)?.text
                == "而是一套能理解代码库",
            "只有一行中文的 cue 在仅译文档应显示原文"
        )
        let singleEnglish = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "Hello world")
        ])
        precondition(
            VideoSubtitlePresentation.resolve(track: singleEnglish, mode: .translationOnly, at: 1) == nil,
            "只有一行英文的 cue 在仅译文档仍应返回 nil"
        )
        let englishThenChinese = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "Hello world\n你好世界")
        ])
        precondition(
            VideoSubtitlePresentation.resolve(track: englishThenChinese, mode: .translationOnly, at: 1)?.text
                == "你好世界",
            "英文加中文两行的 cue 在仅译文档只显示中文行"
        )
        precondition(SubtitleDisplayMode.bilingual.next == .translationOnly)
        precondition(SubtitleDisplayMode.translationOnly.next == .off)
        precondition(SubtitleDisplayMode.off.next == .bilingual)

        print("subtitle_presentation_check=passed")
    }
}
