import AppKit
import SwiftUI

/// 离屏渲染一句双语样本，测量时间码基线与英文首行基线的像素偏差。
@main
struct DigestTypographyProof {
    static let canvasWidth: Int = 420
    static let canvasHeight: Int = 72
    static let outputPath = "/tmp/digest-typography-proof.png"
    static let timeColumnMinX = 10
    static let timeColumnMaxX = 62
    static let textColumnMinX = 72
    static let firstLineBandMaxY = 28

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        OpenMyChrome.applyAppearance()

        let root = DigestTypographyProofView()
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

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

        guard let rep = makeBitmap(hosting: hosting) else {
            fatalError("digest_typography_proof: 无法生成位图")
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("digest_typography_proof: 无法编码 PNG")
        }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            fatalError("digest_typography_proof: 写 PNG 失败 \(error)")
        }

        let timeBaseline = bottomInkRow(
            in: rep,
            xMin: timeColumnMinX,
            xMax: timeColumnMaxX,
            yMax: firstLineBandMaxY,
            kind: .anyGlyph
        )
        let englishBaseline = bottomInkRow(
            in: rep,
            xMin: textColumnMinX,
            xMax: canvasWidth - 10,
            yMax: firstLineBandMaxY,
            kind: .muted
        )
        guard let timeBaseline, let englishBaseline else {
            fatalError(
                "digest_typography_proof: 找不到基线 time=\(String(describing: timeBaseline)) english=\(String(describing: englishBaseline)) png=\(outputPath)"
            )
        }
        let delta = timeBaseline - englishBaseline
        print("digest_typography_proof timeBaseline=\(timeBaseline) englishBaseline=\(englishBaseline) delta=\(delta)px png=\(outputPath)")
        precondition(
            abs(delta) <= 1,
            "时间码与英文首行基线偏差 \(delta)px，超过 1px"
        )
        window.close()
        print("digest_typography_proof=passed")
    }

    private static func makeBitmap(hosting: NSHostingView<DigestTypographyProofView>) -> NSBitmapImageRep? {
        let bounds = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: canvasWidth,
            pixelsHigh: canvasHeight,
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

    enum InkKind {
        case anyGlyph
        case muted
    }

    private static func bottomInkRow(
        in rep: NSBitmapImageRep,
        xMin: Int,
        xMax: Int,
        yMax: Int,
        kind: InkKind
    ) -> Int? {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard let data = rep.bitmapData else { return nil }
        let stride = rep.bytesPerRow
        let spp = max(rep.samplesPerPixel, 4)
        var bottom: Int?
        let yLimit = min(yMax, height - 1)
        for y in 0...yLimit {
            for x in xMin..<min(xMax, width) {
                let offset = y * stride + x * spp
                let r = data[offset]
                let g = data[offset + 1]
                let b = data[offset + 2]
                if isBackground(r, g, b) { continue }
                switch kind {
                case .anyGlyph:
                    bottom = y
                case .muted:
                    if isMuted(r, g, b) { bottom = y }
                }
            }
        }
        return bottom
    }

    private static func isBackground(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        r < 40 && g < 40 && b < 40
    }

    private static func isMuted(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        let maxc = max(r, g, b)
        let minc = min(r, g, b)
        return maxc > 80 && maxc < 200 && Int(maxc) - Int(minc) < 50
    }
}

private final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 1 }
}

private struct DigestTypographyProofView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: OpenMyChrome.nsCanvas)
            DigestCueRow(
                timeLabel: "0:06",
                cueText: "Hello world.\n大家好。",
                timeColumnWidth: 52
            )
            .padding(.horizontal, 10)
            .padding(.vertical, DigestCueDisplay.rowVerticalPadding)
        }
        .frame(width: 420, height: 72)
    }
}
