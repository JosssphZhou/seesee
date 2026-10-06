import Foundation

@main
struct SubtitleRankCheck {
    static func main() {
        func rank(_ suffix: String) -> Int {
            SubtitleTrackRank.value(forStem: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE." + suffix)
        }

        precondition(rank("zh") < rank("en"), "bilingual .zh must beat English")
        precondition(rank("en") < rank("zh-Hans"), "English must beat YouTube zh-Hans")
        precondition(rank("en") < rank("zh-Hant"), "English must beat YouTube zh-Hant")
        precondition(rank("en-orig") < rank("zh-Hans"), "en-orig must beat zh-Hans")
        precondition(rank("en") < rank("zh-Hans-en"), "English must beat zh-Hans-en")
        precondition(rank("zh") < rank("zh-Hans"), "bilingual .zh must beat zh-Hans")
        precondition(rank("zh-Hans") < rank("ko"), "zh-Hans still ranks above unrelated langs")

        let lifeOS = [
            "9D0A346E-068C-41CE-B3FC-938A773AADC9.zh-Hans.srt",
            "9D0A346E-068C-41CE-B3FC-938A773AADC9.en.srt",
            "9D0A346E-068C-41CE-B3FC-938A773AADC9.en-orig.srt",
            "9D0A346E-068C-41CE-B3FC-938A773AADC9.zh-Hant.srt"
        ].map { URL(fileURLWithPath: "/tmp/" + $0) }
        let winner = lifeOS.min { lhs, rhs in
            let left = SubtitleTrackRank.value(for: lhs)
            let right = SubtitleTrackRank.value(for: rhs)
            if left != right { return left < right }
            return lhs.lastPathComponent.count < rhs.lastPathComponent.count
        }
        precondition(
            winner?.lastPathComponent.hasSuffix(".en.srt") == true,
            "Life OS Tour without bilingual must pick English, got \(winner?.lastPathComponent ?? "nil")"
        )

        let withBilingual = lifeOS + [
            URL(fileURLWithPath: "/tmp/9D0A346E-068C-41CE-B3FC-938A773AADC9.zh.srt")
        ]
        let bilingualWinner = withBilingual.min { lhs, rhs in
            let left = SubtitleTrackRank.value(for: lhs)
            let right = SubtitleTrackRank.value(for: rhs)
            if left != right { return left < right }
            return lhs.lastPathComponent.count < rhs.lastPathComponent.count
        }
        precondition(
            bilingualWinner?.lastPathComponent.hasSuffix(".zh.srt") == true,
            "bilingual .zh must win when present"
        )

        print("subtitle_rank_check=passed")
    }
}
