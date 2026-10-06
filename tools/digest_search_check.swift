import Foundation

@main
struct DigestSearchCheck {
    static func main() {
        func cue(_ start: Double, _ text: String) -> VideoSubtitleCue {
            VideoSubtitleCue(startTime: start, endTime: start + 2, text: text)
        }

        let cues = [
            cue(0, "Agents can plan."),
            cue(10, "AGENTS can act."),
            cue(20, "Agents can learn."),
            cue(30, "A.B punctuation"),
            cue(40, "人工智能帮助人，人工智能也需要人。")
        ]

        let agents = DigestTranscriptSearch.matchingCueIndices(in: cues, query: "agents")
        precondition(agents == [0, 1, 2], "大小写不敏感，须命中全部 agents 句，实际 \(agents)")

        let punct = DigestTranscriptSearch.matchingCueIndices(in: cues, query: "A.B")
        precondition(punct == [3], "标点按字面匹配，实际 \(punct)")

        let chinese = DigestTranscriptSearch.matchingCueIndices(in: cues, query: "人工智能")
        precondition(chinese == [4], "中文须命中，实际 \(chinese)")

        precondition(DigestTranscriptSearch.matchingCueIndices(in: cues, query: "   ").isEmpty)
        precondition(DigestTranscriptSearch.matchingCueIndices(in: cues, query: "").isEmpty)

        let ranges = DigestTranscriptSearch.ranges(in: "人工智能帮助人，人工智能也需要人。", query: "人工智能")
        precondition(ranges.count == 2, "同一句内多处命中都要标出，实际 \(ranges.count)")

        precondition(DigestTranscriptSearch.step(current: nil, count: 5, delta: 1) == 0)
        precondition(DigestTranscriptSearch.step(current: nil, count: 5, delta: -1) == 4)
        precondition(DigestTranscriptSearch.step(current: 0, count: 5, delta: 1) == 1)
        precondition(DigestTranscriptSearch.step(current: 4, count: 5, delta: 1) == 0, "下一个在末条须回到第一条")
        precondition(DigestTranscriptSearch.step(current: 0, count: 5, delta: -1) == 4, "上一个在首条须跳到末条")
        precondition(DigestTranscriptSearch.step(current: 0, count: 0, delta: 1) == nil)

        print("digest_search_check=passed")
    }
}
