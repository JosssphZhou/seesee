import AppKit
import Foundation

@main
struct SubtitleOverlayLayoutCheck {
    static func main() {
        // 固定测宽：每个字符在 1pt 字号下占 1pt，便于用字面量推导期望值。
        let measure: (String, CGFloat) -> CGFloat = { text, size in
            CGFloat(text.count) * size
        }

        precondition(SubtitleOverlayLayout.maxOverlayWidth == 900)
        precondition(
            SubtitleOverlayLayout.measurementSlack >= 8,
            "单行测宽必须留出安全余量，避免尾词换进不可见第二行"
        )
        precondition(SubtitleOverlayLayout.lineBreakMode(wraps: false) == .byTruncatingTail)
        precondition(SubtitleOverlayLayout.lineBreakMode(wraps: true) == .byWordWrapping)
        precondition(SubtitleOverlayLayout.maximumLineCount(wraps: false) == 1)
        precondition(SubtitleOverlayLayout.maximumLineCount(wraps: true) == 0)
        precondition(SubtitleOverlayLayout.baseFontSize(forSurfaceWidth: 420) == 16)
        precondition(SubtitleOverlayLayout.baseFontSize(forSurfaceWidth: 800) == 24)
        precondition(SubtitleOverlayLayout.baseFontSize(forSurfaceWidth: 1_280) == 32)
        precondition(SubtitleOverlayLayout.baseFontSize(forSurfaceWidth: 1_920) == 40)
        precondition(
            SubtitleOverlayLayout.baseFontSize(forSurfaceWidth: 1_920)
                > SubtitleOverlayLayout.baseFontSize(forSurfaceWidth: 800),
            "全屏基准字号必须明显大于窗口模式"
        )

        let english = "I've heard this before"
        let chinese = "我听过"
        let window = SubtitleOverlayLayout.resolve(
            lines: [english, chinese],
            surfaceWidth: 800,
            measure: measure
        )
        let chineseOnly = SubtitleOverlayLayout.resolve(
            lines: [chinese],
            surfaceWidth: 800,
            measure: measure
        )
        precondition(window.lines.count == 2)
        precondition(
            window.overlayWidth > chineseOnly.overlayWidth,
            "浮层宽度应取两行中较宽者，不得被短译文压窄"
        )
        precondition(window.lines[0].fontSize == 24, "英文行在窗口宽度内应保持基准字号")
        precondition(window.lines[1].fontSize == 24, "短译文应独立保持基准字号")
        precondition(!window.lines[0].isTruncated)
        precondition(!window.lines[1].isTruncated)
        precondition(window.overlayWidth <= SubtitleOverlayLayout.maxOverlayWidth)

        let independent = SubtitleOverlayLayout.resolve(
            lines: [String(repeating: "A", count: 80), "短"],
            surfaceWidth: 800,
            measure: measure
        )
        precondition(independent.lines.count == 2)
        precondition(
            independent.lines[0].fontSize < independent.lines[1].fontSize,
            "超长原文应单独缩小，短译文不得被牵连"
        )
        precondition(independent.lines[1].fontSize == 24)
        precondition(!independent.lines[0].isTruncated)
        precondition(!independent.lines[1].isTruncated)

        let narrow = SubtitleOverlayLayout.resolve(
            lines: [String(repeating: "W", count: 120), "短译"],
            surfaceWidth: 320,
            measure: measure
        )
        precondition(narrow.overlayWidth <= 320)
        precondition(!narrow.lines[0].isTruncated, "最窄窗口下也不得截断到省略号")
        precondition(
            narrow.lines[0].wraps || narrow.lines[0].fontSize
                < SubtitleOverlayLayout.baseFontSize(forSurfaceWidth: 320),
            "超长英文在最窄窗口下应缩小字号或折行"
        )
        precondition(
            narrow.lines[1].fontSize == SubtitleOverlayLayout.baseFontSize(forSurfaceWidth: 320),
            "短译文在窄窗口下仍保持自身基准字号"
        )

        let fullscreen = SubtitleOverlayLayout.resolve(
            lines: [english, chinese],
            surfaceWidth: 1_920,
            measure: measure
        )
        precondition(
            fullscreen.lines[0].fontSize > window.lines[0].fontSize,
            "全屏原文字号应大于窗口模式，实际全屏 \(fullscreen.lines[0].fontSize) 窗口 \(window.lines[0].fontSize)"
        )
        precondition(fullscreen.overlayWidth <= SubtitleOverlayLayout.maxOverlayWidth)

        let longFullscreen = SubtitleOverlayLayout.resolve(
            lines: [String(repeating: "A", count: 80), "短"],
            surfaceWidth: 1_920,
            measure: measure
        )
        precondition(longFullscreen.lines[0].fontSize == 40, "全屏长句应保持分级字号并折行，不得压回窗口字号")
        precondition(longFullscreen.lines[0].wraps)
        precondition(longFullscreen.lines[1].fontSize == 40)
        precondition(!longFullscreen.lines[0].isTruncated)

        let floatingSurface: CGFloat = 420
        let floatingLong = SubtitleOverlayLayout.resolve(
            lines: [
                "I've heard this before and I want the whole sentence visible.",
                "我听过这句话，希望整句都完整显示在小窗里。"
            ],
            surfaceWidth: floatingSurface
        )
        precondition(
            floatingLong.overlayWidth <= floatingSurface,
            "小窗字幕浮层必须落入 \(floatingSurface)，实际 \(floatingLong.overlayWidth)"
        )
        precondition(
            floatingLong.lines.allSatisfy { $0.fontSize <= 16 },
            "小窗基准字号必须按 420 宽取 16，实际 \(floatingLong.lines.map(\.fontSize))"
        )
        precondition(floatingLong.lines.allSatisfy { !$0.isTruncated })

        let hiddenInset = SubtitleOverlayLayout.overlayBottomInset(controlsVisible: false)
        let visibleInset = SubtitleOverlayLayout.overlayBottomInset(controlsVisible: true)
        precondition(hiddenInset == 16)
        precondition(visibleInset > hiddenInset, "悬浮控制条出现时字幕必须上移避让")

        let realType = SubtitleOverlayLayout.resolve(
            lines: [
                "I've heard this before and I want the whole sentence visible.",
                "我听过"
            ],
            surfaceWidth: 800
        )
        precondition(realType.lines.count == 2)
        precondition(!realType.lines[0].isTruncated)
        precondition(!realType.lines[1].isTruncated)
        precondition(realType.lines[0].fontSize >= 12)
        precondition(
            realType.overlayWidth > 80,
            "真实英文行必须把浮层撑到足够宽度，实际 \(realType.overlayWidth)"
        )

        let englishWidth = 22 * 24
        precondition(!window.lines[0].wraps)
        precondition(
            window.contentWidth >= CGFloat(englishWidth) + SubtitleOverlayLayout.measurementSlack,
            "单行态内容宽度必须大于测宽加余量，实际 \(window.contentWidth) 测宽 \(englishWidth)"
        )

        let months = "at Cursor for about five months"
        let monthsTranslation = "Cursor工作了大约五个月。"
        let monthsLayout = SubtitleOverlayLayout.resolve(
            lines: [months, monthsTranslation],
            surfaceWidth: 800
        )
        let monthsMeasured = SubtitleOverlayLayout.measureText(
            months,
            fontSize: monthsLayout.lines[0].fontSize
        )
        if monthsLayout.lines[0].wraps {
            precondition(SubtitleOverlayLayout.maximumLineCount(wraps: true) == 0)
            precondition(!monthsLayout.lines[0].isTruncated)
        } else {
            precondition(
                monthsLayout.contentWidth >= monthsMeasured + SubtitleOverlayLayout.measurementSlack,
                "临界句单行态必须留余量，否则 months 会静默丢失。内容宽 \(monthsLayout.contentWidth) 测宽 \(monthsMeasured)"
            )
            precondition(
                SubtitleOverlayLayout.lineBreakMode(wraps: false) == .byTruncatingTail,
                "单行态必须用省略号兜底，禁止 word wrap 把尾词换进不可见行"
            )
        }

        let tightMeasure: (String, CGFloat) -> CGFloat = { text, _ in
            text == months ? 740 : 80
        }
        let tight = SubtitleOverlayLayout.resolve(
            lines: [months, monthsTranslation],
            surfaceWidth: 800,
            measure: tightMeasure
        )
        precondition(tight.lines[0].text == months)
        precondition(
            tight.lines[0].wraps || tight.contentWidth >= 740 + SubtitleOverlayLayout.measurementSlack,
            "测宽顶满预算时必须折行或把浮层撑出余量，不得刚好贴边单行。wraps=\(tight.lines[0].wraps) content=\(tight.contentWidth)"
        )
        precondition(!tight.lines[0].isTruncated)

        print("subtitle_overlay_layout_check=passed")
    }
}
