import AppKit
import Foundation

/// 右栏双语句块的显示层排版：原文上、译文下，字号与行高锁死，两行都走中西文垫空格。
enum DigestCueDisplay {
    static let originalSize: CGFloat = 11
    static let translationSize: CGFloat = 13
    static let originalLineMultiple: CGFloat = 1.45
    static let translationLineMultiple: CGFloat = 1.5
    static let pairSpacing: CGFloat = 2
    static let blockSpacing: CGFloat = 3
    static let rowVerticalPadding: CGFloat = 8

    /// 时间码字体（与 SwiftUI `.system(size: 11).monospacedDigit()` 同一套）。
    static var timeFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: originalSize, weight: .regular)
    }

    /// SwiftUI 时间码 Text 顶到基线的距离。
    static var timeBaselineFromTop: CGFloat {
        timeFont.ascender
    }

    /// NSTextView 顶（inset=0、padding=0）到英文首行基线的距离。
    /// 强制行高会在字模上方留空，所以不能用 font.ascender 代替。
    static var firstLineBaselineFromTop: CGFloat {
        let sample = NSAttributedString(
            string: "Hello world.",
            attributes: attributes(
                size: originalSize,
                lineMultiple: originalLineMultiple,
                paragraphSpacing: 0,
                weight: .regular,
                color: .white
            )
        )
        let storage = NSTextStorage(attributedString: sample)
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        let container = NSTextContainer(size: NSSize(width: 400, height: 200))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        guard manager.numberOfGlyphs > 0 else { return timeBaselineFromTop }
        let fragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let location = manager.location(forGlyphAt: 0)
        return fragment.minY + location.y
    }

    static func blockHeight(for text: String, width: CGFloat) -> CGFloat {
        let attributed = attributedString(
            text: text,
            query: "",
            isCurrent: false,
            originalColor: .white,
            translationColor: .white
        )
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        let container = NSTextContainer(size: NSSize(width: max(width, 1), height: 10_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        return max(ceil(used), ceil(translationSize * translationLineMultiple))
    }

    struct Lines: Equatable {
        var original: String?
        var translation: String
    }

    static func lines(from text: String) -> Lines {
        let parts = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let translation = parts.dropFirst().joined(separator: "\n")
        let isDuplicated = parts.count >= 2 && translation == parts[0]
        if parts.count >= 2, !isDuplicated {
            return Lines(
                original: SubtitleSentenceBlocks.withCJKLatinSpacing(parts[0]),
                translation: SubtitleSentenceBlocks.withCJKLatinSpacing(parts.dropFirst().joined(separator: "\n"))
            )
        }
        let body = isDuplicated ? translation : (parts.first ?? text)
        return Lines(original: nil, translation: SubtitleSentenceBlocks.withCJKLatinSpacing(body))
    }

    static func attributedString(
        text: String,
        query: String,
        isCurrent: Bool,
        originalColor: NSColor,
        translationColor: NSColor
    ) -> NSAttributedString {
        let lines = lines(from: text)
        let result = NSMutableAttributedString()
        if let original = lines.original {
            result.append(NSAttributedString(
                string: original + "\n",
                attributes: attributes(
                    size: originalSize,
                    lineMultiple: originalLineMultiple,
                    paragraphSpacing: pairSpacing,
                    weight: .regular,
                    color: originalColor
                )
            ))
        }
        result.append(NSAttributedString(
            string: lines.translation,
            attributes: attributes(
                size: translationSize,
                lineMultiple: translationLineMultiple,
                paragraphSpacing: 0,
                weight: isCurrent ? .semibold : .regular,
                color: translationColor
            )
        ))
        highlight(result, query: query)
        return result
    }

    static func attributes(
        size: CGFloat,
        lineMultiple: CGFloat,
        paragraphSpacing: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> [NSAttributedString.Key: Any] {
        let lineHeight = size * lineMultiple
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 0
        style.paragraphSpacing = paragraphSpacing
        style.paragraphSpacingBefore = 0
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style
        ]
    }

    private static func highlight(_ result: NSMutableAttributedString, query: String) {
        let needle = DigestTranscriptSearch.normalizedQuery(query)
        guard !needle.isEmpty else { return }
        let full = result.string as NSString
        var search = 0
        while search < full.length {
            let found = full.range(
                of: needle,
                options: [.caseInsensitive],
                range: NSRange(location: search, length: full.length - search)
            )
            if found.location == NSNotFound { break }
            result.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.38),
                range: found
            )
            search = found.location + found.length
        }
    }
}
