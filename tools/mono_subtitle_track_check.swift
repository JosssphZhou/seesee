import AppKit
import Foundation

/// 只有一种语言的字幕轨，一条 cue 折成两行时第二行不是译文。
/// 从读字幕文件的入口走，核对浮层、右栏和 MCP `current_subtitles` 三处：
/// 单语轨整句一行、没有译文；双语轨第二行仍是译文。
@main
struct MonoSubtitleTrackCheck {
    /// 《Me at the zoo》（jNQXAC9IVRw）上传者的英文字幕，按 1.0 实测时 MCP 返回的 cue 原样重建。
    static let zooSRT = """
    1
    00:00:01,200 --> 00:00:03,360
    All right, so here we are, in front of the
    elephants

    2
    00:00:05,318 --> 00:00:07,974
    the cool thing about these guys is that they
    have really...

    3
    00:00:07,974 --> 00:00:12,616
    really really long trunks

    4
    00:00:12,616 --> 00:00:14,367
    and that's cool

    5
    00:00:14,421 --> 00:00:15,733
    (baaaaaaaaaaahhh!!)

    6
    00:00:16,881 --> 00:00:18,881
    and that's pretty much all there is to
    say
    """

    /// 中英双语访谈《Anthropic engineer: "You don't need better prompts…"》合并轨的前 8 条。
    static let bilingualSRT = """
    1
    00:00:00,180 --> 00:00:01,721
    I think the number one tip we have for
    我认为我们最重要的建议是

    2
    00:00:02,301 --> 00:00:03,441
    you know, both people inside and
    无论是公司内部还是

    3
    00:00:03,661 --> 00:00:05,062
    and outside Anthropic is that like
    Anthropic 外部的人，都应该

    4
    00:00:05,122 --> 00:00:06,122
    if you
    如果你

    5
    00:00:05,842 --> 00:00:06,842
    treat
    把

    6
    00:00:06,382 --> 00:00:08,163
    Claude like a thought partner and give it
    Claude 当作思考伙伴，并提供

    7
    00:00:08,223 --> 00:00:10,284
    like the context that you need
    你需要的背景信息

    8
    00:00:10,704 --> 00:00:12,825
    then you can usually figure out the next steps
    那么你通常就能找出下一步
    """

    /// 中文原声字幕一条折成两行，同样是一句话，合起来不垫空格。
    static let chineseSRT = """
    1
    00:00:01,000 --> 00:00:03,000
    今天我们来聊一聊
    长视频的字幕

    2
    00:00:03,000 --> 00:00:05,000
    先从下载说起
    """

    nonisolated(unsafe) static var failures: [String] = []

    static func main() {
        checkMonolingualEnglish()
        checkMonolingualChinese()
        checkBilingualUnchanged()
        guard failures.isEmpty else {
            failures.forEach { print("失败：\($0)") }
            print("mono_subtitle_track_check=failed (\(failures.count))")
            exit(1)
        }
        print("mono_subtitle_track_check=passed")
    }

    /// 不在第一处就停，三处各自报出来。
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    private static func checkMonolingualEnglish() {
        let track = load(zooSRT, name: "zoo.en.srt")
        expect(track.cues.count == 6, "《Me at the zoo》应读出 6 条，实际 \(track.cues.count)")

        // 浮层：第一行进原文条，其余进译文条。单语轨只能有一行。
        let overlay = overlayLines(track, at: 2.0)
        expect(
            overlay == ["All right, so here we are, in front of the elephants"],
            "单语浮层应整句一行，实际 \(overlay)"
        )
        expect(
            overlayLines(track, at: 17.5) == ["and that's pretty much all there is to say"],
            "单语浮层末句应整句一行，实际 \(overlayLines(track, at: 17.5))"
        )

        // 右栏：句块拆成原文与译文两行，单语轨不应拆出原文行。
        for block in SubtitleSentenceBlocks.aggregate(track.cues) {
            let lines = DigestCueDisplay.lines(from: block.text)
            expect(lines.original == nil, "单语右栏不应拆出加粗第二行：\(block.text)")
        }
        let firstBlock = DigestCueDisplay.lines(from: SubtitleSentenceBlocks.aggregate(track.cues)[0].text)
        expect(
            firstBlock.translation.hasPrefix("All right, so here we are, in front of the elephants the cool thing"),
            "单语右栏首句应接成一整句，实际 \(firstBlock.translation)"
        )

        // MCP current_subtitles：单语轨 translation 为 null，original 是整句。
        for cue in track.cues {
            let object = NowPlayingQuery.cueObject(cue)
            expect(object["translation"] is NSNull, "单语 MCP translation 应为 null：\(object)")
            expect(object["original"] as? String == object["text"] as? String, "单语 MCP original 应是整句：\(object)")
        }
        let first = NowPlayingQuery.cueObject(track.cues[0])
        expect(
            first["original"] as? String == "All right, so here we are, in front of the elephants",
            "单语 MCP 首句 original 应是整句，实际 \(first["original"] ?? "")"
        )
    }

    private static func checkMonolingualChinese() {
        let track = load(chineseSRT, name: "zh-native.zh-Hans.srt")
        expect(
            overlayLines(track, at: 2.0) == ["今天我们来聊一聊长视频的字幕"],
            "中文单语两行应直接相接，实际 \(overlayLines(track, at: 2.0))"
        )
        expect(NowPlayingQuery.cueObject(track.cues[0])["translation"] is NSNull, "中文单语 MCP translation 应为 null")
    }

    private static func checkBilingualUnchanged() {
        let track = load(bilingualSRT, name: "interview.zh.srt")
        expect(track.cues == VideoSubtitleTrack.parse(bilingualSRT), "双语轨读入后不应改动任何 cue")

        expect(
            overlayLines(track, at: 0.5) == ["I think the number one tip we have for", "我认为我们最重要的建议是"],
            "双语浮层仍应原文、译文两行，实际 \(overlayLines(track, at: 0.5))"
        )

        let blocks = SubtitleSentenceBlocks.aggregate(track.cues)
        expect(!blocks.isEmpty, "双语右栏应有句块")
        for block in blocks {
            let lines = DigestCueDisplay.lines(from: block.text)
            expect(lines.original != nil, "双语右栏仍应拆出原文行：\(block.text)")
        }

        let object = NowPlayingQuery.cueObject(track.cues[0])
        expect(object["original"] as? String == "I think the number one tip we have for", "双语 MCP original 应是英文行：\(object)")
        expect(object["translation"] as? String == "我认为我们最重要的建议是", "双语 MCP translation 应是中文行：\(object)")
    }

    private static func overlayLines(_ track: VideoSubtitleTrack, at time: Double) -> [String] {
        guard let shown = VideoSubtitlePresentation.resolve(track: track, mode: .bilingual, at: time) else {
            return []
        }
        return VideoSubtitlePresentation.displayLines(from: shown.text)
    }

    private static func load(_ source: String, name: String) -> VideoSubtitleTrack {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mono-subtitle-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try! source.write(to: url, atomically: true, encoding: .utf8)
        guard let track = VideoSubtitleTrack(contentsOf: url) else {
            preconditionFailure("读不出字幕文件 \(name)")
        }
        return track
    }
}
