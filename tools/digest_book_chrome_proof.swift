import AppKit
import SwiftUI

@main
struct DigestBookChromeProof {
    static let normalPath = "/tmp/digest-book-chrome-normal.png"
    static let narrowPath = "/tmp/digest-book-chrome-narrow.png"
    static let normalWidth: CGFloat = 300
    static let narrowWidth: CGFloat = 232

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        OpenMyChrome.applyAppearance()
        assertRemovedTypes()

        render(width: normalWidth, path: normalPath)
        render(width: narrowWidth, path: narrowPath)
        print("digest_book_chrome_proof=passed")
    }

    @MainActor
    private static func render(width: CGFloat, path: String) {
        let sink = HitSink()
        let root = DigestBookChromeProofView(width: width, sink: sink)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let height: CGFloat = 96
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

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

        guard let rep = makeBitmap(hosting: hosting, width: Int(width), height: Int(height)),
              let png = rep.representation(using: .png, properties: [:])
        else {
            fatalError("digest_book_chrome_proof: 无法生成 \(path)")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fatalError("digest_book_chrome_proof: 写 \(path) 失败 \(error)")
        }

        let hits = sink.hits
        guard let toc = hits["toc"] else {
            fatalError("digest_book_chrome_proof: 有章节时须显示目录行 width=\(width)")
        }
        precondition(
            toc.maxX <= width + 0.5 && toc.minX >= -0.5,
            "目录行超出栏宽 \(width)：\(toc)"
        )
        print("digest_book_chrome_proof width=\(Int(width)) toc=\(Int(toc.height))h/\(Int(toc.width))w png=\(path)")
        window.close()
    }

    private static func assertRemovedTypes() {
        let repo = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = repo.appendingPathComponent("Sources/seesee")
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: sources,
                includingPropertiesForKeys: nil
            )
        } catch {
            fatalError("digest_book_chrome_proof: 读不到 Sources/seesee \(error)")
        }
        let names = Set(files.map(\.lastPathComponent))
        precondition(!names.contains("DigestModeTabs.swift"), "页签模块不得留在分支")
        var blob = ""
        for file in files where file.pathExtension == "swift" {
            blob += (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }
        precondition(!blob.contains("struct DigestModeTabs"), "页签视图不得存在")
        precondition(!blob.contains("struct DigestSelectionBar"), "拖选工具条不得存在")
        precondition(!blob.contains("struct SelectableCueText"), "拖选文本不得存在")
        precondition(!blob.contains("struct DigestOverviewPage"), "总览页不得存在")
        precondition(!blob.contains("struct DigestNotesPage"), "笔记页不得存在")
        // 播放器里不再内置 AI：不得再有模型服务地址和密钥设置。
        for marker in ["api.anthropic.com", "generativelanguage.googleapis.com", "AnthropicAPIKey", "GeminiAPIKey"] {
            precondition(!blob.contains(marker), "播放器源码不得再有 AI 调用或密钥：\(marker)")
        }
    }

    private static func makeBitmap(hosting: NSView, width: Int, height: Int) -> NSBitmapImageRep? {
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        return rep
    }
}

final class HitSink {
    var hits: [String: CGRect] = [:]
}

private struct DigestBookChromeProofView: View {
    let width: CGFloat
    let sink: HitSink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DigestBookToolbar(
                query: "",
                onQueryChange: { _ in },
                matchCount: 0,
                activeIndex: nil,
                step: { _ in }
            )
            DigestTOCBanner(
                chapters: [
                    VideoChapter(title: "开场", startTime: 0, endTime: 120),
                    VideoChapter(title: "方法", startTime: 120, endTime: 300)
                ],
                duration: 300,
                isExpanded: false,
                currentTime: 8,
                timeColumnWidth: 52,
                onToggleExpand: {},
                onSeek: { _ in }
            )
        }
        .frame(width: width, height: 96, alignment: .top)
        .background(OpenMyChrome.canvas)
        .coordinateSpace(name: "digest-book-page")
        .onPreferenceChange(DigestBookHitKey.self) { sink.hits = $0 }
    }
}

private final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 1 }
}
