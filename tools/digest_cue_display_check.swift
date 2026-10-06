import AppKit
import Foundation

@main
struct DigestCueDisplayCheck {
    static func main() {
        checkTypographyCaps()
        checkLineOrderAndSpacing()
        checkCJKOnBothLines()
        checkAttributedFonts()
        print("digest_cue_display_check=passed")
    }

    private static func checkTypographyCaps() {
        precondition(DigestCueDisplay.translationSize == 13, "译文主行必须 13px")
        precondition(DigestCueDisplay.translationSize <= 13, "译文禁止超过 13px")
        precondition(DigestCueDisplay.originalSize == 11)
        precondition(DigestCueDisplay.originalLineMultiple == 1.45)
        precondition(DigestCueDisplay.translationLineMultiple == 1.5)
        precondition((2...3).contains(DigestCueDisplay.pairSpacing))
        precondition(DigestCueDisplay.blockSpacing == 3)
        precondition(DigestCueDisplay.rowVerticalPadding == 8)
        let first = DigestCueDisplay.firstLineBaselineFromTop
        let time = DigestCueDisplay.timeBaselineFromTop
        precondition(first > 0 && first < 24, "英文首行基线须在句块顶部附近，实际 \(first)")
        precondition(time > 0 && time < 24, "时间码基线须在字号范围内，实际 \(time)")
    }

    private static func checkLineOrderAndSpacing() {
        let lines = DigestCueDisplay.lines(from: "Hello everyone.\n大家好。")
        precondition(lines.original == "Hello everyone.")
        precondition(lines.translation == "大家好。")

        let duplicated = DigestCueDisplay.lines(from: "Lauren Tan\nLauren Tan")
        precondition(duplicated.original == nil, "原文译文相同时只留一行")
        precondition(duplicated.translation == "Lauren Tan")
    }

    private static func checkCJKOnBothLines() {
        let mixed = DigestCueDisplay.lines(from: "I am Lauren Tan\nLauren Tan我想没多少人知道我的姓名。")
        precondition(mixed.original == "I am Lauren Tan")
        precondition(
            mixed.translation.contains("Tan\u{2009}我"),
            "译文中西文相接必须垫窄空格，实际 \(mixed.translation)"
        )

        let noSpace = DigestCueDisplay.lines(from: "Hi\nLauren Tan我想")
        precondition(
            noSpace.translation.contains("Tan\u{2009}我"),
            "无空格的 Tan我想 也必须垫，实际 \(noSpace.translation)"
        )

        let originalMixed = DigestCueDisplay.lines(from: "在Twitter上叫Potato。\n在推特上叫土豆。")
        precondition(originalMixed.original == "在\u{2009}Twitter\u{2009}上叫\u{2009}Potato。")
    }

    private static func checkAttributedFonts() {
        let attributed = DigestCueDisplay.attributedString(
            text: "Hello everyone.\nLauren Tan我想。",
            query: "",
            isCurrent: false,
            originalColor: .gray,
            translationColor: .white
        )
        let full = attributed.string
        precondition(full.contains("Hello everyone."))
        precondition(full.contains("Tan\u{2009}我"), "NSTextView 用的 attributedString 也必须已垫空格")

        var originalOK = false
        var translationOK = false
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let snippet = (attributed.string as NSString).substring(with: range)
            if snippet.contains("Hello") {
                precondition(font.pointSize == 11, "原文必须 11px，实际 \(font.pointSize)")
                originalOK = true
            }
            if snippet.contains("我想") {
                precondition(font.pointSize == 13, "译文必须 13px，实际 \(font.pointSize)")
                precondition(font.pointSize <= 13)
                translationOK = true
            }
        }
        precondition(originalOK && translationOK, "两行字体都要落到 attributedString")

        var pairSpacingOK = false
        attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let snippet = (attributed.string as NSString).substring(with: range)
            if snippet.contains("Hello") {
                precondition(style.paragraphSpacing == 2, "同块两行间距须为 2px，实际 \(style.paragraphSpacing)")
                precondition(style.minimumLineHeight == 11 * 1.45)
                precondition(style.maximumLineHeight == 11 * 1.45)
                pairSpacingOK = true
            }
            if snippet.contains("我想") {
                precondition(style.minimumLineHeight == 13 * 1.5)
                precondition(style.maximumLineHeight == 13 * 1.5)
                precondition(style.maximumLineHeight <= 13 * 1.5)
            }
        }
        precondition(pairSpacingOK)
    }
}
