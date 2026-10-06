import AppKit

enum SubtitleOverlayLayout {
    static let maxOverlayWidth: CGFloat = 900
    static let surfaceMargin: CGFloat = 16
    static let contentPadding: CGFloat = 28
    static let defaultBottomInset: CGFloat = 16
    static let floatingControlsBottomInset: CGFloat = 88
    /// NSTextField 内边距与亚像素会比 `size(withAttributes:)` 更窄；无余量时尾词会被换进不可见第二行。
    static let measurementSlack: CGFloat = 12

    struct LineDecision: Equatable {
        var text: String
        var fontSize: CGFloat
        var width: CGFloat
        var wraps: Bool
        var isTruncated: Bool
    }

    struct Decision: Equatable {
        var overlayWidth: CGFloat
        var lines: [LineDecision]

        var contentWidth: CGFloat {
            max(1, overlayWidth - SubtitleOverlayLayout.contentPadding)
        }
    }

    static func baseFontSize(forSurfaceWidth width: CGFloat) -> CGFloat {
        switch width {
        case ..<600:
            return 16
        case ..<1_280:
            return 24
        case ..<1_920:
            return 32
        default:
            return 40
        }
    }

    static func minimumFontSize(forBase base: CGFloat) -> CGFloat {
        switch base {
        case ..<20:
            return 11
        case ..<30:
            return 12
        default:
            return 18
        }
    }

    static func overlayBottomInset(controlsVisible: Bool) -> CGFloat {
        controlsVisible ? floatingControlsBottomInset : defaultBottomInset
    }

    static func availableOverlayWidth(surfaceWidth: CGFloat) -> CGFloat {
        max(1, min(maxOverlayWidth, surfaceWidth - surfaceMargin * 2))
    }

    static func lineBreakMode(wraps: Bool) -> NSLineBreakMode {
        wraps ? .byWordWrapping : .byTruncatingTail
    }

    static func maximumLineCount(wraps: Bool) -> Int {
        wraps ? 0 : 1
    }

    static func fits(_ measured: CGFloat, in available: CGFloat) -> Bool {
        measured + measurementSlack <= available
    }

    static func resolve(
        lines: [String],
        surfaceWidth: CGFloat,
        measure: (String, CGFloat) -> CGFloat = measureText
    ) -> Decision {
        let visibleLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let base = baseFontSize(forSurfaceWidth: surfaceWidth)
        let minimum = minimumFontSize(forBase: base)
        let budget = max(1, availableOverlayWidth(surfaceWidth: surfaceWidth) - contentPadding)
        let naturalWidths = visibleLines.map { measure($0, base) }
        let longest = max(naturalWidths.max() ?? 0, 1)
        let overlayContentWidth = min(budget, longest + measurementSlack)
        let overlayWidth = overlayContentWidth + contentPadding

        let decisions = zip(visibleLines, naturalWidths).map { text, naturalWidth -> LineDecision in
            if fits(naturalWidth, in: overlayContentWidth) {
                return LineDecision(
                    text: text,
                    fontSize: base,
                    width: naturalWidth,
                    wraps: false,
                    isTruncated: false
                )
            }
            // 全屏分级后的大字号优先折行，避免长句被压回窗口字号。
            if base >= 32 {
                return LineDecision(
                    text: text,
                    fontSize: base,
                    width: overlayContentWidth,
                    wraps: true,
                    isTruncated: false
                )
            }
            let target = max(1, overlayContentWidth - measurementSlack)
            let fitted = max(minimum, floor(base * target / max(naturalWidth, 1)))
            let fittedWidth = measure(text, fitted)
            if fits(fittedWidth, in: overlayContentWidth) {
                return LineDecision(
                    text: text,
                    fontSize: fitted,
                    width: fittedWidth,
                    wraps: false,
                    isTruncated: false
                )
            }
            return LineDecision(
                text: text,
                fontSize: fitted,
                width: overlayContentWidth,
                wraps: true,
                isTruncated: false
            )
        }
        return Decision(overlayWidth: overlayWidth, lines: decisions)
    }

    static func measureText(_ text: String, fontSize: CGFloat) -> CGFloat {
        let font = roundedFont(size: fontSize)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func roundedFont(size: CGFloat) -> NSFont {
        let baseFont = NSFont.systemFont(ofSize: size, weight: .semibold)
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded)
        return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? baseFont
    }
}
