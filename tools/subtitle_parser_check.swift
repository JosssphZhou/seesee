import Foundation

@main
struct SubtitleParserCheck {
    static func main() {
        let srt = """
        1
        00:00:01,250 --> 00:00:03,500
        Hello <i>offline</i> world &amp; friends.

        2
        00:00:03,500 --> 00:00:05,000
        Second line
        continues here.
        """
        let srtCues = VideoSubtitleTrack.parse(srt)
        precondition(srtCues.count == 2)
        precondition(srtCues[0].startTime == 1.25)
        precondition(srtCues[0].text == "Hello offline world & friends.")
        let srtTrack = VideoSubtitleTrack(cues: srtCues)
        precondition(srtTrack.text(at: 0.5) == nil)
        precondition(srtTrack.text(at: 2) == "Hello offline world & friends.")
        precondition(srtTrack.text(at: 4) == "Second line\ncontinues here.")
        precondition(srtTrack.cue(at: 2)?.text == "Hello offline world & friends.")
        precondition(srtTrack.cue(at: 0.5) == nil)

        let vtt = """
        WEBVTT

        cue-1
        00:06.000 --> 00:08.250 align:middle
        A WebVTT caption
        """
        let vttCues = VideoSubtitleTrack.parse(vtt)
        precondition(vttCues.count == 1)
        precondition(vttCues[0].startTime == 6)
        precondition(vttCues[0].endTime == 8.25)

        // YouTube 滚动字幕：10ms 闪现 cue 紧跟更长扩展句，歌词轴会成对重复。
        // 样本取自韩语工作音乐 .zh.srt 8:52 一带（双语两行保留）。
        let rollingSrt = """
        1
        00:08:51,750 --> 00:08:51,760
        rhythm in the beat. Nothing loud and
        节拍中安静的节奏。没有喧嚣，没有

        2
        00:08:51,760 --> 00:08:54,710
        rhythm in the beat. Nothing loud and nothing strong. Just the city's moving
        节拍中安静的节奏。没有喧嚣，没有强烈。只有城市流动的

        3
        00:08:54,710 --> 00:08:54,720
        nothing strong. Just the city's moving
        没有强烈。只有城市流动的

        4
        00:08:54,720 --> 00:08:57,910
        nothing strong. Just the city's moving song. Coffee warmth and open view.
        没有强烈。只有城市流动的歌声。咖啡的温暖和开阔的视野。
        """
        let rollingCues = VideoSubtitleTrack.parse(rollingSrt)
        precondition(
            rollingCues.count == 2,
            "expected flash cues collapsed, got \(rollingCues.count)"
        )
        precondition(rollingCues[0].startTime == 531.76)
        precondition(rollingCues[0].endTime == 534.71)
        precondition(rollingCues[0].text.contains("\n"), "bilingual two-line cue must stay intact")
        precondition(rollingCues[0].text.contains("nothing strong"))
        precondition(rollingCues[0].text.contains("节拍中安静的节奏"))
        precondition(rollingCues[1].startTime == 534.72)
        precondition(rollingCues[1].text.contains("Coffee warmth"))
        precondition(rollingCues[1].text.contains("咖啡的温暖"))
        // 画面字幕取数：扩展句时间窗内仍是双语两行
        let rollingTrack = VideoSubtitleTrack(cues: rollingCues)
        let caption = rollingTrack.text(at: 533)
        precondition(caption != nil)
        precondition(caption!.contains("\n"))
        precondition(caption!.contains("rhythm in the beat"))
        precondition(caption!.contains("节拍中安静的节奏"))

        // 正常邻接 cue（时长均非闪现）不得被误删
        let normalAdjacent = """
        1
        00:00:01,000 --> 00:00:03,000
        Hello

        2
        00:00:03,000 --> 00:00:05,000
        World
        """
        let normalCues = VideoSubtitleTrack.parse(normalAdjacent)
        precondition(normalCues.count == 2)
        precondition(normalCues[0].text == "Hello")
        precondition(normalCues[1].text == "World")

        // 极短但内容无关（审查 S1）：不得因时长邻接误删
        let distinctShort = """
        1
        00:00:01,000 --> 00:00:01,040
        [door slams]

        2
        00:00:01,040 --> 00:00:03,000
        Hello
        """
        let distinctCues = VideoSubtitleTrack.parse(distinctShort)
        precondition(
            distinctCues.count == 2,
            "distinct short cue must be kept, got \(distinctCues.count)"
        )
        precondition(distinctCues[0].text == "[door slams]")
        precondition(distinctCues[0].startTime == 1.0)
        precondition(distinctCues[0].endTime == 1.04)
        precondition(distinctCues[1].text == "Hello")
        precondition(distinctCues[1].startTime == 1.04)

        // YouTube 两行滚动窗：长窗 + 10ms 闪现。拆成一句一行，闪现不占条。
        let youtubeRoll = """
        1
        00:00:00,000 --> 00:00:01,590

        In this video, I'm going to show you how

        2
        00:00:01,590 --> 00:00:01,600
        In this video, I'm going to show you how
         

        3
        00:00:01,600 --> 00:00:03,669
        In this video, I'm going to show you how
        I use Notion to manage every aspect of

        4
        00:00:03,669 --> 00:00:03,679
        I use Notion to manage every aspect of
         

        5
        00:00:03,679 --> 00:00:05,800
        I use Notion to manage every aspect of
        my life. From daily tasks to finances to
        """
        let youtubeCues = VideoSubtitleTrack.parse(youtubeRoll)
        precondition(
            youtubeCues.count == 3,
            "expected 3 unrolled lines, got \(youtubeCues.count) \(youtubeCues.map(\.text))"
        )
        precondition(youtubeCues.allSatisfy { !$0.text.contains("\n") })
        precondition(youtubeCues[0].text == "In this video, I'm going to show you how")
        precondition(youtubeCues[0].startTime == 0)
        precondition(abs(youtubeCues[0].endTime - 3.679) < 0.0001)
        precondition(youtubeCues[1].text == "I use Notion to manage every aspect of")
        precondition(abs(youtubeCues[1].startTime - 1.6) < 0.0001)
        precondition(youtubeCues[2].text == "my life. From daily tasks to finances to")
        let youtubeTrack = VideoSubtitleTrack(cues: youtubeCues)
        let spoken = youtubeTrack.text(at: 2.0)
        precondition(spoken == "I use Notion to manage every aspect of", "got \(spoken ?? "nil")")
        precondition(youtubeTrack.text(at: 0.5) == "In this video, I'm going to show you how")

        // 连续、重叠的双语 cue 全程都有文字。播放器仍须用 cue 身份识别换句，
        // 否则 SwiftUI 只会原位替换 Text 内容，不会执行字幕转场。
        let bilingualTrack = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 3.6, text: "First line\n第一行"),
            VideoSubtitleCue(startTime: 1.6, endTime: 5.2, text: "Second line\n第二行")
        ])
        let firstPresentationCue = bilingualTrack.cue(at: 1.0)
        let secondPresentationCue = bilingualTrack.cue(at: 2.0)
        precondition(firstPresentationCue?.text == "First line\n第一行")
        precondition(secondPresentationCue?.text == "Second line\n第二行")
        precondition(
            firstPresentationCue?.id != secondPresentationCue?.id,
            "连续双语字幕换句时必须更换视图身份，才能触发统一转场"
        )
        let repeatedTextCue = VideoSubtitleCue(startTime: 6, endTime: 8, text: "First line\n第一行")
        precondition(
            firstPresentationCue?.id != repeatedTextCue.id,
            "文字相同但时间段不同的 cue 也必须有不同身份"
        )

        if CommandLine.arguments.count > 1 {
            let downloadedURL = URL(fileURLWithPath: CommandLine.arguments[1])
            guard let downloadedTrack = VideoSubtitleTrack(contentsOf: downloadedURL) else {
                preconditionFailure("Could not parse the downloaded subtitle fixture")
            }
            precondition(downloadedTrack.cues.count > 10)
            print("downloaded_subtitle_cues=\(downloadedTrack.cues.count)")
        }

        print("subtitle_parser_check=passed")
    }
}
