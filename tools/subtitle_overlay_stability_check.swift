import AppKit
import QuartzCore

/// 离屏驱动真实的 PlayerSubtitleOverlayView，依次换句「两行 → 一行 → 折行长句 → 两行」，
/// 转场期间每 1/60 秒按呈现层（屏幕上正在显示的动画中间态）取帧，断言：
/// 新句最后一行底边与旧句最后一行底边的偏差不超过 1 点，新句底条不做尺寸动画，
/// 旧句淡出期间的可见区域与换句前完全一致（不移动、不伸缩、不被裁切）。
/// 环境变量 SUBTITLE_PROBE_VERBOSE=1 打印逐帧数据，SUBTITLE_PROBE_FRAMES=<目录> 导出逐帧图片。
@main
struct SubtitleOverlayStabilityCheck {
    struct Scene {
        let name: String
        let surface: NSSize
        let steps: [String]
        let animated: Bool
    }

    struct Sample {
        let t: Double
        let lastLineBottom: CGFloat
        let stackTop: CGFloat
        let pills: [CGSize]
        let fonts: [CGFloat]
        let liveOpacity: Float
        let ghostVisible: CGRect?
        let ghostOpacity: Float
    }

    static let tolerance: CGFloat = 1
    static let frameInterval = 1.0 / 60
    static let frameCount = 24
    static let verbose = ProcessInfo.processInfo.environment["SUBTITLE_PROBE_VERBOSE"] == "1"
    static let framesDirectory = ProcessInfo.processInfo.environment["SUBTITLE_PROBE_FRAMES"]

    static let bilingualSteps = [
        "We should keep the subtitles steady.\n我们应该让字幕保持稳定。",
        "对，就是这样。",
        "And when the sentence gets really long, with several clauses stacked one after another, the renderer has to decide whether it should shrink the text or wrap it onto another line.\n当句子变得很长、好几个从句一个接一个叠在一起时，渲染器必须决定是缩小字号还是折到下一行。",
        "Then we go back to normal.\n然后我们回到正常。"
    ]

    static let translationSteps = [
        "我们应该让字幕保持稳定。",
        "对。",
        "当句子变得很长、好几个从句一个接一个叠在一起的时候，渲染器必须决定到底是缩小字号，还是把整句折到下一行去显示。",
        "然后我们回到正常。"
    ]

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            print("subtitle_overlay_stability: 系统开启了「减少动态效果」，换句不做动画，只检查直接替换")
        }

        let scenes = [
            Scene(name: "窗口双语", surface: NSSize(width: 800, height: 450), steps: bilingualSteps, animated: true),
            Scene(name: "全屏双语", surface: NSSize(width: 1_920, height: 1_080), steps: bilingualSteps, animated: true),
            Scene(name: "小窗双语", surface: NSSize(width: 420, height: 236), steps: bilingualSteps, animated: true),
            Scene(name: "窗口仅译文", surface: NSSize(width: 800, height: 450), steps: translationSteps, animated: true),
            Scene(name: "直接替换", surface: NSSize(width: 800, height: 450), steps: bilingualSteps, animated: false)
        ]

        var failures: [String] = []
        for scene in scenes {
            failures += run(scene)
        }
        for interruption in Interruption.allCases {
            failures += run(interruption)
        }
        if failures.isEmpty {
            print("subtitle_overlay_stability=passed")
            return
        }
        for failure in failures {
            FileHandle.standardError.write(Data("subtitle_overlay_stability: \(failure)\n".utf8))
        }
        exit(1)
    }

    @MainActor
    static func run(_ scene: Scene) -> [String] {
        let host = ProbeHost(frame: NSRect(origin: .zero, size: scene.surface))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.3, alpha: 1).cgColor
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        let overlay = PlayerSubtitleOverlayView()
        overlay.install(in: host)
        host.overlay = overlay
        host.layoutSubtreeIfNeeded()

        // 冻结宿主层的动画时钟，逐帧手动推进：取帧、导出图片的耗时不会让动画跑到前面去。
        guard let clockLayer = host.layer else { fatalError("宿主没有 layer") }
        var clock: CFTimeInterval = 100
        func setClock(_ time: CFTimeInterval) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clockLayer.speed = 0
            clockLayer.timeOffset = time
            CATransaction.commit()
            CATransaction.flush()
        }
        setClock(clock)

        var failures: [String] = []
        var frameIndex = 0
        for (index, text) in scene.steps.enumerated() {
            let presentation = VideoSubtitlePresentation(
                id: VideoSubtitleCueID(startTime: Double(index), endTime: Double(index) + 1, text: text),
                text: text
            )
            let before = settledGeometry(overlay: overlay, host: host)
            overlay.setPresentation(presentation, animated: scene.animated)
            // 提交事务，动画以冻结时钟的当前时刻为起点。
            CATransaction.flush()
            let start = clock

            var samples: [Sample] = []
            for step in 0..<frameCount {
                clock = start + Double(step) * frameInterval
                setClock(clock)
                samples.append(sample(t: clock - start, overlay: overlay, host: host))
                exportFrame(host: host, scene: scene, index: frameIndex)
                frameIndex += 1
            }
            // 推过所有动画的终点，再让主线程收掉到期的旧句快照。
            clock = start + 10
            setClock(clock)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let after = sample(t: -1, overlay: overlay, host: host)
            let leftover = overlay.layer.map { snapshotLayers(in: $0).count } ?? 0
            if leftover > 0 {
                failures.append("[\(scene.name)] 第 \(index) 次换句：转场结束后仍有 \(leftover) 个旧句快照层没有移除")
            }

            if verbose {
                print("[\(scene.name)] 第 \(index) 次换句 -> \(text.split(separator: "\n").first ?? "")")
                if let before {
                    print(String(format: "  换句前 底边 %.1f 句块 %@", before.lastLineBottom, NSStringFromRect(before.stackRect)))
                }
                for s in samples {
                    let ghost = s.ghostVisible.map { NSStringFromRect($0) } ?? "-"
                    print(String(
                        format: "  t=%.3f 底边 %.1f 顶边 %.1f 新句透明度 %.2f 底条 %@ 字号 %@ 旧句可见区 %@ 旧句透明度 %.2f",
                        s.t, s.lastLineBottom, s.stackTop, s.liveOpacity,
                        s.pills.map { String(format: "%.0fx%.0f", $0.width, $0.height) }.joined(separator: ","),
                        s.fonts.map { String(format: "%.0f", $0) }.joined(separator: ","),
                        ghost, s.ghostOpacity
                    ))
                }
            }

            guard let before else { continue }
            let label = "[\(scene.name)] 第 \(index) 次换句"
            let bottomDrift = samples.map { abs($0.lastLineBottom - before.lastLineBottom) }.max() ?? 0
            if bottomDrift > tolerance {
                failures.append("\(label)：新句最后一行底边偏离旧句底边最多 \(fmt(bottomDrift)) 点（允许 \(fmt(tolerance))）")
            }
            let pillDrift = samples.flatMap { s in
                zip(s.pills, after.pills).map { max(abs($0.width - $1.width), abs($0.height - $1.height)) }
            }.max() ?? 0
            if pillDrift > tolerance {
                failures.append("\(label)：新句底条在转场中做了尺寸动画，最大差 \(fmt(pillDrift)) 点")
            }
            for s in samples where s.ghostOpacity > 0.01 {
                guard let visible = s.ghostVisible else { continue }
                let drift = max(
                    abs(visible.minX - before.stackRect.minX),
                    abs(visible.minY - before.stackRect.minY),
                    abs(visible.width - before.stackRect.width),
                    abs(visible.height - before.stackRect.height)
                )
                if drift > tolerance {
                    failures.append(
                        "\(label)：旧句淡出时 t=\(String(format: "%.3f", s.t)) 可见区域 \(NSStringFromRect(visible)) 偏离换句前 \(NSStringFromRect(before.stackRect))，差 \(fmt(drift)) 点"
                    )
                    break
                }
            }
            if !scene.animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                if samples.contains(where: { $0.ghostOpacity > 0.01 || $0.liveOpacity < 0.99 }) {
                    failures.append("\(label)：不做动画时应直接替换，却出现了旧句残影或新句淡入")
                }
            }
        }
        return failures
    }

    /// 换句后 0.05 秒（交叉渐隐进行到一半）发生的、不走交叉渐隐的变化。
    enum Interruption: String, CaseIterable {
        case seek = "拖动进度条"
        case subtitlesOffOn = "关字幕再开"
        case resize = "窗口变窄"
    }

    /// 打断的那一刻旧句快照必须立即消失、新句立即不透明，不能偏离原位继续淡出。
    @MainActor
    static func run(_ interruption: Interruption) -> [String] {
        let host = ProbeHost(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        host.wantsLayer = true
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        let overlay = PlayerSubtitleOverlayView()
        overlay.install(in: host)
        host.overlay = overlay
        host.layoutSubtreeIfNeeded()
        guard let clockLayer = host.layer, let overlayLayer = overlay.layer else { fatalError("宿主没有 layer") }
        func setClock(_ time: CFTimeInterval) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clockLayer.speed = 0
            clockLayer.timeOffset = time
            CATransaction.commit()
            CATransaction.flush()
        }
        func presentation(_ index: Int) -> VideoSubtitlePresentation {
            let text = bilingualSteps[index]
            return VideoSubtitlePresentation(
                id: VideoSubtitleCueID(startTime: Double(index), endTime: Double(index) + 1, text: text),
                text: text
            )
        }

        setClock(100)
        overlay.setPresentation(presentation(0), animated: false)
        host.layoutSubtreeIfNeeded()
        overlay.setPresentation(presentation(1), animated: true)
        CATransaction.flush()
        setClock(100.05)
        let label = "[中途\(interruption.rawValue)]"
        guard !snapshotLayers(in: overlayLayer).isEmpty else {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return [] }
            return ["\(label)：换句后 0.05 秒应当正在交叉渐隐，却没有旧句快照，场景无效"]
        }

        switch interruption {
        case .seek:
            overlay.setPresentation(presentation(3), animated: false)
        case .subtitlesOffOn:
            overlay.setPresentation(nil, animated: false)
            overlay.setPresentation(presentation(3), animated: true)
        case .resize:
            window.setContentSize(NSSize(width: 600, height: 450))
        }
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()

        var failures: [String] = []
        let leftover = snapshotLayers(in: overlayLayer).count
        if leftover > 0 {
            failures.append("\(label)：打断后旧句快照没有立即移除，还剩 \(leftover) 个")
        }
        let live = sample(t: 0, overlay: overlay, host: host)
        // 关字幕再开是整条浮层按原样淡入，只检查快照；另两种是直接替换，新句必须立即不透明。
        if interruption != .subtitlesOffOn, live.liveOpacity < 0.99 {
            failures.append("\(label)：打断后新句应立即不透明，实际透明度 \(String(format: "%.2f", live.liveOpacity))")
        }
        if verbose {
            print("\(label) 打断后快照层 \(leftover) 个，新句透明度 \(String(format: "%.2f", live.liveOpacity))")
        }
        return failures
    }

    struct Geometry {
        let lastLineBottom: CGFloat
        let stackRect: CGRect
    }

    @MainActor
    static func settledGeometry(overlay: PlayerSubtitleOverlayView, host: NSView) -> Geometry? {
        let fields = liveFields(in: overlay)
        guard !fields.isEmpty, overlay.alphaValue > 0.99,
              let stack = fields.first?.superview?.superview else { return nil }
        let bottom = fields.map { host.convert($0.bounds, from: $0).minY }.min() ?? 0
        return Geometry(lastLineBottom: bottom, stackRect: host.convert(stack.bounds, from: stack))
    }

    @MainActor
    static func sample(t: Double, overlay: PlayerSubtitleOverlayView, host: NSView) -> Sample {
        guard let hostLayer = host.layer else { fatalError("宿主没有 layer") }
        let fields = liveFields(in: overlay)
        let fieldRects = fields.compactMap { $0.layer.map { presentedRect($0, in: hostLayer) } }
        let pills = fields.compactMap { $0.superview?.layer.map { presentedRect($0, in: hostLayer).size } }
        let stackTop = fields.first?.superview?.superview?.layer.map { presentedRect($0, in: hostLayer).maxY } ?? 0
        let liveOpacity = fields.first?.layer.map { presentedOpacity($0, below: hostLayer) } ?? 0

        var ghostVisible: CGRect?
        var ghostOpacity: Float = 0
        if let overlayLayer = overlay.layer, let ghost = snapshotLayers(in: overlayLayer).last {
            ghostVisible = visibleRect(ghost, in: hostLayer)
            ghostOpacity = presentedOpacity(ghost, below: hostLayer)
        }
        return Sample(
            t: t,
            lastLineBottom: fieldRects.map(\.minY).min() ?? 0,
            stackTop: stackTop,
            pills: pills,
            fonts: fields.compactMap { $0.font?.pointSize },
            liveOpacity: liveOpacity,
            ghostVisible: ghostVisible,
            ghostOpacity: ghostOpacity
        )
    }

    static func liveFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        for subview in view.subviews {
            if let field = subview as? NSTextField {
                if !field.isHidden, !field.stringValue.isEmpty, field.superview?.isHidden == false {
                    result.append(field)
                }
            } else {
                result += liveFields(in: subview)
            }
        }
        return result
    }

    /// 不属于任何视图、带位图内容的层就是旧句快照；新句句块和文字框内部的绘制层不算。
    static func snapshotLayers(in layer: CALayer) -> [CALayer] {
        var result: [CALayer] = []
        for sublayer in layer.sublayers ?? [] {
            if sublayer.delegate is NSStackView || sublayer.delegate is NSTextField { continue }
            if !(sublayer.delegate is NSView), sublayer.contents != nil {
                result.append(sublayer)
            }
            result += snapshotLayers(in: sublayer)
        }
        return result
    }

    static func presented(_ layer: CALayer) -> CALayer {
        layer.presentation() ?? layer
    }

    static func presentedRect(_ layer: CALayer, in root: CALayer) -> CGRect {
        let p = presented(layer)
        return p.convert(p.bounds, to: presented(root))
    }

    static func presentedOpacity(_ layer: CALayer, below root: CALayer) -> Float {
        var opacity: Float = 1
        var current: CALayer? = layer
        while let node = current, node !== root {
            opacity *= presented(node).opacity
            current = node.superlayer
        }
        return opacity
    }

    /// 快照层与所有裁切祖先的交集，即观众实际看得到的区域。
    static func visibleRect(_ layer: CALayer, in root: CALayer) -> CGRect {
        var rect = presentedRect(layer, in: root)
        var current = layer.superlayer
        while let node = current, node !== root {
            if node.masksToBounds {
                rect = rect.intersection(presentedRect(node, in: root))
            }
            current = node.superlayer
        }
        return rect
    }

    @MainActor
    static func exportFrame(host: NSView, scene: Scene, index: Int) {
        guard let directory = framesDirectory, let layer = host.layer else { return }
        let scale: CGFloat = 2
        let width = Int(host.bounds.width * scale)
        let height = Int(host.bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        presented(layer).render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let folder = URL(fileURLWithPath: directory).appendingPathComponent(scene.name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: folder.appendingPathComponent(String(format: "%04d.png", index)))
    }

    static func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}

/// 照 PlayerLayerHostView 的写法：宿主尺寸变化和布局时把自身宽度告诉浮层。
final class ProbeHost: NSView {
    weak var overlay: PlayerSubtitleOverlayView?

    override func layout() {
        super.layout()
        overlay?.updateForSurfaceWidth(bounds.width)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        overlay?.updateForSurfaceWidth(newSize.width)
    }
}
