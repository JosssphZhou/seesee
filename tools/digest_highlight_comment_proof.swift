import AppKit
import SwiftUI

@main
struct DigestHighlightCommentProof {
    static let fieldPath = "/tmp/digest-highlight-comment-field.png"
    static let typingPath = "/tmp/digest-highlight-comment-typing.png"
    static let savedPath = "/tmp/digest-highlight-comment-saved.png"
    static let narrowPath = "/tmp/digest-highlight-comment-field-narrow.png"
    static let wideWidth = 360
    static let canvasHeight = 220

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        OpenMyChrome.applyAppearance()

        precondition(DigestBookChrome.commentFieldHeight == 28)
        precondition(DigestBookChrome.commentFieldPadding == 10)
        precondition(DigestBookChrome.commentPlaceholder == "写一句批语")
        precondition(DigestBookChrome.commentHintIdle == "回车保存 · Esc 只留划线")
        precondition(DigestBookChrome.commentHintTyping == "回车保存")
        precondition(DigestBookChrome.commentBarLabel == "批语")
        precondition(DigestBookChrome.unhighlightTitle == "取消划线")

        let empty = render(.emptyBar, width: wideWidth, path: fieldPath)
        printMetrics(name: "输入条空态", result: empty)
        assertBar(empty, expectedHint: DigestBookChrome.commentHintIdle, expectSaved: false)

        let typing = render(.typingBar, width: wideWidth, path: typingPath)
        printMetrics(name: "输入中", result: typing)
        assertBar(typing, expectedHint: DigestBookChrome.commentHintTyping, expectSaved: false)

        let saved = render(.saved, width: wideWidth, path: savedPath)
        printMetrics(name: "保存后文本行", result: saved)
        guard let savedComment = saved.hits["comment"] else {
            fatalError("digest_highlight_comment_proof: 已保存须画出文本行")
        }
        precondition(saved.hits["comment-pen"] != nil, "已保存须有笔形图标")
        precondition(saved.hits["comment-bar"] == nil, "保存后不得保留输入条")
        precondition(
            savedComment.height + 0.5 < DigestBookChrome.commentFieldHeight,
            "已保存须是文本行，不得保留输入框高度：\(savedComment.height)"
        )

        let narrow = render(
            .emptyBar,
            width: Int(DigestBookChrome.minColumnWidth),
            path: narrowPath
        )
        printMetrics(name: "最窄栏宽输入条", result: narrow)
        assertBar(narrow, expectedHint: DigestBookChrome.commentHintIdle, expectSaved: false)
        if let bar = narrow.hits["comment-bar"] {
            let trailing = CGFloat(Int(DigestBookChrome.minColumnWidth)) - bar.maxX
            precondition(trailing <= 1, "最窄栏宽输入条须占满栏宽：trailing=\(trailing)")
            precondition(bar.minX <= 0.5, "最窄栏宽输入条左缘须贴栏边：minX=\(bar.minX)")
        }

        print(
            "digest_highlight_comment_proof field=\(fieldPath) typing=\(typingPath) saved=\(savedPath) narrow=\(narrowPath)"
        )
        print("digest_highlight_comment_proof=passed")
    }

    enum ProofState {
        case emptyBar
        case typingBar
        case saved
    }

    @MainActor
    private static func assertBar(
        _ result: RenderResult,
        expectedHint: String,
        expectSaved: Bool
    ) {
        guard let bar = result.hits["comment-bar"] else {
            fatalError("digest_highlight_comment_proof: 须画出底部输入条")
        }
        guard let caption = result.hits["comment-bar-caption"] else {
            fatalError("digest_highlight_comment_proof: 须画出输入条第一行")
        }
        guard let fieldView = result.fieldView else {
            fatalError("digest_highlight_comment_proof: 找不到输入框视图")
        }
        precondition(result.hits["comment"] == nil || expectSaved, "划线后未保存不得出现句内批语行")
        precondition(bar.maxY <= CGFloat(canvasHeight) + 0.5, "输入条不得超出侧栏")
        precondition(caption.minY + 0.5 >= bar.minY, "第一行须在输入条内")
        precondition(
            abs(fieldView.bounds.height - DigestBookChrome.commentFieldHeight) < 1.5,
            "输入框高度须为 28，实际 \(fieldView.bounds.height)"
        )
        precondition(
            abs(fieldView.field.frame.minX - DigestBookChrome.commentFieldPadding) < 1,
            "左内边距须为 10，实际 \(fieldView.field.frame.minX)"
        )
        let fill = hexString(fieldView.layer?.backgroundColor)
        precondition(fill == "#1E1E1E", "底色须为 raise #1E1E1E，实际 \(fill)")
        precondition(abs((fieldView.layer?.cornerRadius ?? -1) - 8) < 0.5, "圆角须为 8")
        precondition(abs((fieldView.layer?.borderWidth ?? -1) - 1) < 0.1, "描边须为 1 点")
        precondition(
            fieldView.hintLabel.stringValue == expectedHint,
            "提示须为「\(expectedHint)」，实际「\(fieldView.hintLabel.stringValue)」"
        )
        let needed = DigestCommentHintLayout.width(of: expectedHint)
        if DigestCommentHintLayout.shouldShow(columnWidth: fieldView.bounds.width, hint: expectedHint) {
            precondition(!fieldView.hintLabel.isHidden, "列宽足够时提示须完整显示")
            precondition(
                fieldView.hintLabel.frame.width + 0.5 >= needed,
                "提示不得截断：frame=\(fieldView.hintLabel.frame.width) 文本=\(needed)"
            )
        } else {
            precondition(fieldView.hintLabel.isHidden, "列宽不足时提示须整体隐藏")
        }
    }

    @MainActor
    private static func printMetrics(name: String, result: RenderResult) {
        print("---- \(name) ----")
        print("  comment-bar=\(fmtRect(result.hits["comment-bar"]))")
        print("  caption=\(fmtRect(result.hits["comment-bar-caption"]))")
        print("  comment=\(fmtRect(result.hits["comment"]))")
        print("  cue-text=\(fmtRect(result.hits["cue-text"]))")
        if let fieldView = result.fieldView {
            print(
                "  chrome=\(fmtNS(fieldView.bounds)) field=\(fmtNS(fieldView.field.frame)) hint=\(fmtNS(fieldView.hintLabel.frame))"
            )
            print(
                "  fill=\(hexString(fieldView.layer?.backgroundColor)) border=\(hexString(fieldView.layer?.borderColor)) hiddenHint=\(fieldView.hintLabel.isHidden) hintText=\(fieldView.hintLabel.stringValue)"
            )
        }
        if let pen = result.hits["comment-pen"] {
            print("  comment-pen=\(fmtRect(pen))")
        }
    }

    @MainActor
    private static func render(_ state: ProofState, width: Int, path: String) -> RenderResult {
        let sink = CommentHitSink()
        let root = DigestHighlightCommentProofView(state: state, canvasWidth: width, sink: sink)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let size = CGSize(width: width, height: canvasHeight)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = OneXWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = OpenMyChrome.nsCanvas
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        hosting.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let fieldView = findCommentField(in: hosting)
        fieldView?.layoutSubtreeIfNeeded()

        let bounds = NSRect(origin: .zero, size: size)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: canvasHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { fatalError("digest_highlight_comment_proof: 无法生成位图 \(path)") }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("digest_highlight_comment_proof: 无法编码 \(path)")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fatalError("digest_highlight_comment_proof: 写 \(path) 失败 \(error)")
        }
        window.close()
        return RenderResult(hits: sink.hits, fieldView: fieldView)
    }

    private static func findCommentField(in view: NSView) -> DigestCommentFieldView? {
        if let field = view as? DigestCommentFieldView { return field }
        for child in view.subviews {
            if let found = findCommentField(in: child) { return found }
        }
        return nil
    }

    private static func fmt(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private static func fmtRect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return "x=\(fmt(rect.minX)) y=\(fmt(rect.minY)) w=\(fmt(rect.width)) h=\(fmt(rect.height)) maxY=\(fmt(rect.maxY))"
    }

    private static func fmtNS(_ rect: NSRect) -> String {
        "x=\(fmt(rect.minX)) y=\(fmt(rect.minY)) w=\(fmt(rect.width)) h=\(fmt(rect.height))"
    }

    private static func hexString(_ color: CGColor?) -> String {
        guard let color else { return "nil" }
        guard let converted = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let comps = converted.components, comps.count >= 3 else {
            return "nil"
        }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

struct RenderResult {
    var hits: [String: CGRect]
    var fieldView: DigestCommentFieldView?
}

final class CommentHitSink {
    var hits: [String: CGRect] = [:]
}

private struct DigestHighlightCommentProofView: View {
    let state: DigestHighlightCommentProof.ProofState
    let canvasWidth: Int
    let sink: CommentHitSink

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                DigestBookToolbar(
                    query: "",
                    onQueryChange: { _ in },
                    matchCount: 0,
                    activeIndex: nil,
                    highlightCount: 1,
                    step: { _ in }
                )
                VStack(alignment: .leading, spacing: 0) {
                    DigestCueRow(
                        timeLabel: "0:10",
                        cueText: "Hello world.\n大家好。",
                        timeColumnWidth: 52,
                        isHighlighted: true
                    )
                    if state == .saved {
                        DigestHighlightCommentRow(text: "这句是关键")
                            .padding(.top, DigestBookChrome.commentFieldSpacing)
                            .padding(.leading, 62)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .padding(.vertical, DigestCueDisplay.rowVerticalPadding)
                Spacer(minLength: 0)
            }
            if state != .saved {
                DigestCommentBar(
                    timeLabel: "0:10",
                    sentence: DigestCueDisplay.lines(from: "Hello world.\n大家好。").translation,
                    draft: state == .typingBar ? "这句是关键" : ""
                )
            }
        }
        .frame(
            width: CGFloat(canvasWidth),
            height: CGFloat(DigestHighlightCommentProof.canvasHeight),
            alignment: .top
        )
        .background(OpenMyChrome.canvas)
        .coordinateSpace(name: "digest-book-page")
        .onPreferenceChange(DigestBookHitKey.self) { sink.hits = $0 }
    }
}

private final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 1 }
}
