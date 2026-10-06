import Foundation

@main
struct URLIntakeCheck {
    static func main() {
        let block = """
        Things to watch:
        - First: https://www.youtube.com/watch?v=abc123&t=45
        - A post (https://twitter.com/example/status/987654321?s=20).
        - Duplicate form: https://youtu.be/abc123
        - Background reading at www.example.com/watch/list.
        Contact person@example.com if anything is missing.
        """

        let extracted = URLIntake.webURLs(from: block).map(\.absoluteString)
        precondition(extracted == [
            "https://www.youtube.com/watch?v=abc123",
            "https://x.com/example/status/987654321",
            "http://www.example.com/watch/list"
        ], "Unexpected extraction: \(extracted)")

        let markdown = "[One](https://example.com/one), [Two](https://example.com/two)."
        let markdownLinks = URLIntake.webURLs(from: markdown).map(\.absoluteString)
        precondition(markdownLinks == ["https://example.com/one", "https://example.com/two"])

        precondition(URLIntake.webURLs(from: "No links in this paragraph.").isEmpty)
        precondition(URLIntake.webURL(from: "https://example.com/single")?.absoluteString == "https://example.com/single")

        // B站：去掉跟踪参数，保留分 P
        let bilibiliTracked = URL(string: "https://www.bilibili.com/video/BV1GJ411x7h7?spm_id_from=333.337&vd_source=abc&p=2")!
        precondition(
            URLIntake.canonicalString(for: bilibiliTracked) == "https://www.bilibili.com/video/BV1GJ411x7h7?p=2",
            "Bilibili should strip tracking but keep p="
        )
        let bilibiliPlain = URL(string: "https://www.bilibili.com/video/BV1GJ411x7h7?spm_id_from=333.337")!
        precondition(
            URLIntake.canonicalString(for: bilibiliPlain) == "https://www.bilibili.com/video/BV1GJ411x7h7",
            "Bilibili without p= should drop all query"
        )

        // 小红书：去掉跟踪参数
        let xhs = URL(string: "https://www.xiaohongshu.com/explore/64abc?xsec_token=foo&share_id=bar")!
        precondition(
            URLIntake.canonicalString(for: xhs) == "https://www.xiaohongshu.com/explore/64abc",
            "Xiaohongshu should strip tracking query"
        )

        // 短链保持原样（不做网络展开）
        let b23 = URL(string: "https://b23.tv/abcdef")!
        precondition(URLIntake.canonicalString(for: b23) == "https://b23.tv/abcdef")
        let xhslink = URL(string: "https://xhslink.com/m/xyz")!
        precondition(URLIntake.canonicalString(for: xhslink) == "https://xhslink.com/m/xyz")

        let largeBlock = (0..<250)
            .map { "Item \($0): https://example.com/watch/\($0)" }
            .joined(separator: "\n")
        let largeBatch = URLIntake.webURLs(from: largeBlock)
        precondition(largeBatch.count == 250)
        precondition(largeBatch.first?.absoluteString == "https://example.com/watch/0")
        precondition(largeBatch.last?.absoluteString == "https://example.com/watch/249")

        print("url_intake_check=passed")
    }
}
