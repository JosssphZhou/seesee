import AppKit
import SwiftUI

@main
struct DigestBookNarrowProof {
    static let width = Int(DigestBookChrome.minColumnWidth)
    static let height = 420

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        OpenMyChrome.applyAppearance()

        let first = render(.firstOpen, path: "/tmp/digest-book-narrow-first-open.png")
        assertInside(first, keys: ["toc", "cue-text"], state: "首次打开")
        assertNoOverlap(first, keys: ["toc", "cue-text"], state: "首次打开")

        let tocExpanded = render(.tocExpanded, path: "/tmp/digest-book-narrow-toc-expanded.png")
        precondition(tocExpanded["toc"] != nil, "展开目录标题须可点")
        let chapterRows = tocExpanded.keys.filter { $0.hasPrefix("toc-chapter-") }
        precondition(chapterRows.count == 2, "展开目录须直接列出视频自带的 2 个章节，实际 \(chapterRows.count)")
        let tocKeys = tocExpanded.keys.filter { $0 == "toc" || $0.hasPrefix("toc-chapter-") }
        assertInside(tocExpanded, keys: Array(tocKeys), state: "目录展开")

        print("digest_book_narrow_proof first=/tmp/digest-book-narrow-first-open.png toc=/tmp/digest-book-narrow-toc-expanded.png")
        print("digest_book_narrow_proof=passed")
    }

    @MainActor
    private static func render(
        _ state: BookState,
        path: String,
        canvasWidth: Int = DigestBookNarrowProof.width
    ) -> [String: CGRect] {
        let sink = NarrowHitSink()
        let root = DigestNarrowBookView(state: state, canvasWidth: canvasWidth, sink: sink)
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
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
        guard let rep else { fatalError("digest_book_narrow_proof: 无法生成位图 \(path)") }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("digest_book_narrow_proof: 无法编码 \(path)")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fatalError("digest_book_narrow_proof: 写 \(path) 失败 \(error)")
        }
        window.close()
        return sink.hits
    }

    private static func assertInside(_ hits: [String: CGRect], keys: [String], state: String) {
        let maxX = CGFloat(width)
        for key in keys {
            guard let rect = hits[key] else {
                fatalError("digest_book_narrow_proof: \(state) 缺少 \(key)")
            }
            precondition(
                rect.minX >= -0.5 && rect.maxX <= maxX + 0.5,
                "\(state) \(key) 超出最窄栏：\(rect)"
            )
            precondition(rect.minY >= -0.5, "\(state) \(key) 顶部越界：\(rect)")
            precondition(rect.width > 1 && rect.height > 1, "\(state) \(key) 不可见：\(rect)")
        }
    }

    private static func assertNoOverlap(_ hits: [String: CGRect], keys: [String], state: String) {
        for index in 0..<keys.count {
            for other in (index + 1)..<keys.count {
                guard let a = hits[keys[index]], let b = hits[keys[other]] else { continue }
                precondition(
                    !a.intersects(b),
                    "\(state) \(keys[index]) 与 \(keys[other]) 重叠：\(a) / \(b)"
                )
            }
        }
    }
}

enum BookState {
    case firstOpen
    case tocExpanded
}

final class NarrowHitSink {
    var hits: [String: CGRect] = [:]
}

private struct DigestNarrowBookView: View {
    let state: BookState
    let canvasWidth: Int
    let sink: NarrowHitSink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DigestBookToolbar(
                query: "",
                onQueryChange: { _ in },
                matchCount: 0,
                activeIndex: nil,
                step: { _ in }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: DigestCueDisplay.blockSpacing) {
                    DigestTOCBanner(
                        chapters: [
                            VideoChapter(title: "开场", startTime: 0, endTime: 120),
                            VideoChapter(title: "方法", startTime: 120, endTime: 300)
                        ],
                        duration: 300,
                        isExpanded: state == .tocExpanded,
                        currentTime: 8,
                        timeColumnWidth: 52,
                        onToggleExpand: {},
                        onSeek: { _ in }
                    )
                    cueBlock
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .frame(width: CGFloat(canvasWidth), height: CGFloat(DigestBookNarrowProof.height), alignment: .top)
        .background(OpenMyChrome.canvas)
        .coordinateSpace(name: "digest-book-page")
        .onPreferenceChange(DigestBookHitKey.self) { sink.hits = $0 }
    }

    private var cueBlock: some View {
        DigestCueRow(
            timeLabel: "0:06",
            cueText: "Hello world.\n大家好。",
            timeColumnWidth: 52,
            onSeek: {}
        )
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, DigestCueDisplay.rowVerticalPadding)
    }
}

private final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 1 }
}
