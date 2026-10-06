import AppKit
import SwiftUI

@main
struct DigestHighlightNotesProof {
    static let commentPath = "/tmp/digest-highlight-comment.png"
    static let filterPath = "/tmp/digest-highlights-only.png"
    static let canvasWidth = 360
    static let commentHeight = 160
    static let filterHeight = 220

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        OpenMyChrome.applyAppearance()

        let commented = render(
            highlightsOnly: false,
            showEmptyComment: false,
            path: commentPath,
            height: commentHeight
        )
        guard commented["comment"] != nil else {
            fatalError("digest_highlight_notes_proof: 带批语的划线句须画出批语行")
        }
        precondition(commented["collapsed-hint"] == nil, "全文态不得出现收起提示")

        let emptyHits = render(
            highlightsOnly: false,
            showEmptyComment: true,
            path: "/tmp/digest-highlight-empty-comment.png",
            height: commentHeight
        )
        precondition(emptyHits["comment"] == nil, "批语为空时不显示批语行")

        let filtered = render(
            highlightsOnly: true,
            showEmptyComment: false,
            path: filterPath,
            height: filterHeight
        )
        guard let hint = filtered["collapsed-hint"] else {
            fatalError("digest_highlight_notes_proof: 只看划线态须有收起提示")
        }
        precondition(hint.height >= 16, "收起提示须可见")
        precondition(filtered["comment"] != nil, "只看划线态须保留批语")
        precondition(filtered["highlight"] != nil, "只看划线态须保留划线入口")

        print("digest_highlight_notes_proof comment=\(commentPath) filter=\(filterPath)")
        print("digest_highlight_notes_proof=passed")
    }

    @MainActor
    private static func render(
        highlightsOnly: Bool,
        showEmptyComment: Bool,
        path: String,
        height: Int
    ) -> [String: CGRect] {
        let sink = HighlightHitSink()
        let root = DigestHighlightProofView(
            highlightsOnly: highlightsOnly,
            showEmptyComment: showEmptyComment,
            sink: sink
        )
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let size = CGSize(width: canvasWidth, height: height)
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

        let bounds = NSRect(origin: .zero, size: size)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: canvasWidth,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { fatalError("digest_highlight_notes_proof: 无法生成位图 \(path)") }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("digest_highlight_notes_proof: 无法编码 \(path)")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fatalError("digest_highlight_notes_proof: 写 \(path) 失败 \(error)")
        }
        window.close()
        return sink.hits
    }
}

final class HighlightHitSink {
    var hits: [String: CGRect] = [:]
}

private struct DigestHighlightProofView: View {
    let highlightsOnly: Bool
    let showEmptyComment: Bool
    let sink: HighlightHitSink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DigestBookToolbar(
                query: "",
                onQueryChange: { _ in },
                matchCount: 0,
                activeIndex: nil,
                highlightCount: 2,
                isFilterActive: highlightsOnly,
                step: { _ in }
            )
            cue(
                time: "0:10",
                text: "Hello world.\n大家好。",
                comment: showEmptyComment ? "" : "这句是关键"
            )
            if highlightsOnly {
                cue(
                    time: "0:40",
                    text: "Keep going.\n继续。",
                    comment: "后面也要看"
                )
                DigestCollapsedHint(hiddenCount: 2)
            }
            Spacer(minLength: 0)
        }
        .frame(
            width: CGFloat(DigestHighlightNotesProof.canvasWidth),
            height: highlightsOnly
                ? CGFloat(DigestHighlightNotesProof.filterHeight)
                : CGFloat(DigestHighlightNotesProof.commentHeight),
            alignment: .top
        )
        .background(OpenMyChrome.canvas)
        .coordinateSpace(name: "digest-book-page")
        .onPreferenceChange(DigestBookHitKey.self) { sink.hits = $0 }
    }

    private func cue(time: String, text: String, comment: String) -> some View {
        VStack(alignment: .leading, spacing: DigestCueDisplay.pairSpacing) {
            DigestCueRow(
                timeLabel: time,
                cueText: text,
                timeColumnWidth: 52,
                isHighlighted: true
            )
            DigestHighlightCommentRow(text: comment)
                .padding(.leading, 62)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, DigestCueDisplay.rowVerticalPadding)
    }
}

private final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 1 }
}
