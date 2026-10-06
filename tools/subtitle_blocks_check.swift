import Foundation

// 句级聚合校验：ASR 逐片 cue 在显示层按句末标点合并，时间取句首，上限防失控。

@main
enum SubtitleBlocksCheck {
    static func main() {
        func cue(_ start: Double, _ end: Double, _ text: String) -> VideoSubtitleCue {
            VideoSubtitleCue(startTime: start, endTime: end, text: text)
        }

        // 1. 三片并成一句：句号闭合，时间取句首，块尾取末片。
        let sentence = SubtitleSentenceBlocks.aggregate([
            cue(0.0, 3.2, "In this video, I'm going to show you the\n在这个视频中，我将向你展示"),
            cue(1.4, 5.3, "exact system I use to manage every\n我用来管理我生活中每个"),
            cue(3.2, 7.4, "aspect of my life\n方面的确切系统。"),
        ])
        precondition(sentence.count == 1, "应聚合为一句，实际 \(sentence.count)")
        precondition(sentence[0].startTime == 0.0)
        precondition(sentence[0].endTime == 7.4)
        let lines = sentence[0].text.components(separatedBy: "\n")
        precondition(lines.count == 2)
        precondition(lines[0] == "In this video, I'm going to show you the exact system I use to manage every aspect of my life")
        precondition(lines[1] == "在这个视频中，我将向你展示我用来管理我生活中每个方面的确切系统。")

        // 2. 两句拆两块：句中闭合即切分。
        let two = SubtitleSentenceBlocks.aggregate([
            cue(0, 2, "Hi everyone.\n大家好。"),
            cue(2, 4, "I am Lauren\n我是 Lauren，"),
            cue(4, 6, "Tan\n谭。"),
        ])
        precondition(two.count == 2, "应为两块，实际 \(two.count)")
        precondition(two[1].startTime == 2)

        // 3. 无标点长流按片数上限切块，不会无限累积。
        let capped = SubtitleSentenceBlocks.aggregate(
            (0..<14).map { cue(Double($0), Double($0) + 1, "part \($0)\n片段\($0)") }
        )
        precondition(capped.count >= 2, "上限切块失效")
        precondition(capped.allSatisfy { $0.text.components(separatedBy: "\n").count == 2 })

        // 4. 跨度上限：单片超长间隔也会闭合。
        let span = SubtitleSentenceBlocks.aggregate([
            cue(0, 13, "a very long fragment\n很长的片段"),
            cue(13, 14, "next\n下一句。"),
        ])
        precondition(span.count == 2, "跨度上限失效，实际 \(span.count)")

        // 5. 纯英文轨按英文标点断句。
        let enOnly = SubtitleSentenceBlocks.aggregate([
            cue(0, 1, "I was at Meta"),
            cue(1, 2, "on the React team."),
            cue(2, 3, "Now at SpaceXAI."),
        ])
        precondition(enOnly.count == 2, "英文断句失效，实际 \(enOnly.count)")

        // 6. 空文本 cue 被跳过，不产生空块。
        let sparse = SubtitleSentenceBlocks.aggregate([
            cue(0, 1, " "),
            cue(1, 2, "只有一句。"),
        ])
        precondition(sparse.count == 1)
        precondition(sparse[0].text == "只有一句。")


        // 7. 满 4 片后遇分句标点提前落刀，硬上限不再拦腰切短语。
        let clause = SubtitleSentenceBlocks.aggregate(
            (0..<5).map { cue(Double($0), Double($0) + 1, "part \($0)\n片段\($0)，") }
        )
        precondition(clause.count == 2, "分句落刀失效，实际 \(clause.count)")
        precondition(clause[0].text.components(separatedBy: "\n")[1].hasSuffix("，"))

        // 8. 聚合层直接拼接不垫空格，排版交给显示层。
        let spaced = SubtitleSentenceBlocks.aggregate([
            cue(0, 1, "Lauren Tan\nLauren Tan"),
            cue(1, 2, "I guess not many people know\n我想没多少人知道我的姓"),
            cue(2, 3, "my last name\n名。"),
        ])
        precondition(spaced.count == 1)
        precondition(spaced[0].text.components(separatedBy: "\n")[1] == "Lauren Tan我想没多少人知道我的姓名。", spaced[0].text)

        // 9. 显示层中西文垫窄空格（U+2009）：全部边界，已有空格不重复垫，纯中文纯英文不动。
        precondition(SubtitleSentenceBlocks.withCJKLatinSpacing("在Twitter上叫Potato。")
            == "在\u{2009}Twitter\u{2009}上叫\u{2009}Potato。")
        precondition(SubtitleSentenceBlocks.withCJKLatinSpacing("E结尾的") == "E\u{2009}结尾的")
        precondition(SubtitleSentenceBlocks.withCJKLatinSpacing("Lauren Tan 我想") == "Lauren Tan\u{2009}我想")
        precondition(SubtitleSentenceBlocks.withCJKLatinSpacing("I am Potato on Twitter") == "I am Potato on Twitter")
        precondition(SubtitleSentenceBlocks.withCJKLatinSpacing("纯中文不变") == "纯中文不变")
        precondition(SubtitleSentenceBlocks.withCJKLatinSpacing("pure english") == "pure english")

        print("subtitle_blocks_check=passed")
    }
}
