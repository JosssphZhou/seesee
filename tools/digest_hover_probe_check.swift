import AppKit
import SwiftUI

/// 回归：离屏窗口里挂真实句行 + ScrollView/LazyVStack，校验 DigestHoverProbeView 几何与追踪区域。
@main
struct DigestHoverProbeCheck {
    static let canvasWidth: CGFloat = 360
    static let canvasHeight: CGFloat = 240
    static let scrollDelta: CGFloat = 200

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        OpenMyChrome.applyAppearance()

        let hover = HoverSink()
        let root = DigestHoverProbeHarness(cues: sampleCues, hover: hover)
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
        layout(hosting: hosting, window: window)

        guard let scrollView = findScrollView(in: hosting) else {
            fatalError("digest_hover_probe_check: 找不到 NSScrollView")
        }

        let beforeCount = inspectProbes(phase: "before-scroll", from: hosting)
        precondition(beforeCount > 0, "滚动前必须至少有一颗句行探针")
        scrollContent(scrollView, delta: scrollDelta)
        layout(hosting: hosting, window: window)
        let afterCount = inspectProbes(phase: "after-scroll-200", from: hosting)
        precondition(
            afterCount >= beforeCount,
            "滚动后可见行探针数量不得减少：before=\(beforeCount) after=\(afterCount)"
        )

        window.close()
        print("digest_hover_probe_check=passed")
    }

    private static let sampleCues: [VideoSubtitleCue] = [
        VideoSubtitleCue(startTime: 0, endTime: 2, text: "Hello world.\n大家好。"),
        VideoSubtitleCue(startTime: 2, endTime: 4, text: "This is the second sentence.\n这是第二句。"),
        VideoSubtitleCue(startTime: 4, endTime: 6, text: "Agents can plan.\n智能体可以做计划。"),
        VideoSubtitleCue(startTime: 6, endTime: 8, text: "Keep going through the list.\n继续往下看清单。"),
        VideoSubtitleCue(startTime: 8, endTime: 10, text: "Another bilingual block.\n又一块双语字幕。"),
        VideoSubtitleCue(startTime: 10, endTime: 12, text: "Enough rows to overflow.\n行数要够才能溢出。"),
        VideoSubtitleCue(startTime: 12, endTime: 14, text: "Last visible after scrolling.\n滚动之后才看见这句。")
    ]

    @MainActor
    private static func layout(hosting: NSView, window: NSWindow) {
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        hosting.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    private static func scrollContent(_ scrollView: NSScrollView, delta: CGFloat) {
        let clip = scrollView.contentView
        let origin = clip.bounds.origin
        clip.scroll(to: NSPoint(x: origin.x, y: origin.y + delta))
        scrollView.reflectScrolledClipView(clip)
    }

    @discardableResult
    private static func inspectProbes(phase: String, from root: NSView) -> Int {
        let probes = collectProbes(from: root)
        print("digest_hover_probe_check phase=\(phase) probeCount=\(probes.count)")
        for (index, probe) in probes.enumerated() {
            precondition(
                probe.bounds.width > 0 && probe.bounds.height > 0,
                "phase=\(phase) probe[\(index)] bounds 须非零，实际 \(probe.bounds)"
            )
            precondition(
                probe.window != nil,
                "phase=\(phase) probe[\(index)] window 不得为空"
            )
            precondition(
                probe.trackingAreas.count == 1,
                "phase=\(phase) probe[\(index)] trackingAreas 须恰好 1 块，实际 \(probe.trackingAreas.count)"
            )
            let options = probe.trackingAreas[0].options
            precondition(
                options.contains(.activeAlways),
                "phase=\(phase) probe[\(index)] 须含 activeAlways，options=\(options.rawValue)"
            )
            precondition(
                options.contains(.inVisibleRect),
                "phase=\(phase) probe[\(index)] 须含 inVisibleRect，options=\(options.rawValue)"
            )
            print(
                "digest_hover_probe_check phase=\(phase) probe[\(index)] " +
                "bounds=\(probe.bounds) window=yes trackingAreas=1 options=\(options.rawValue)"
            )
        }
        return probes.count
    }

    private static func collectProbes(from view: NSView) -> [DigestHoverProbeView] {
        var found: [DigestHoverProbeView] = []
        if let probe = view as? DigestHoverProbeView {
            found.append(probe)
        }
        for child in view.subviews {
            found.append(contentsOf: collectProbes(from: child))
        }
        return found
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView {
            return scroll
        }
        for child in view.subviews {
            if let found = findScrollView(in: child) {
                return found
            }
        }
        return nil
    }
}

final class HoverSink {
    var hoveredCueIndex: Int?
}

private struct DigestHoverProbeHarness: View {
    let cues: [VideoSubtitleCue]
    let hover: HoverSink

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DigestCueDisplay.blockSpacing) {
                ForEach(cues.indices, id: \.self) { index in
                    let cue = cues[index]
                    DigestCueRow(
                        timeLabel: timeLabel(cue.startTime),
                        cueText: cue.text,
                        timeColumnWidth: 52,
                        isCurrent: index == 0,
                        showsActions: hover.hoveredCueIndex == index
                    )
                    .help("跳到这句")
                    .background {
                        DigestHoverMonitor { hovering in
                            if hovering {
                                hover.hoveredCueIndex = index
                            } else if hover.hoveredCueIndex == index {
                                hover.hoveredCueIndex = nil
                            }
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 14)
                    .padding(.vertical, DigestCueDisplay.rowVerticalPadding)
                    .id(index)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(width: DigestHoverProbeCheck.canvasWidth, height: DigestHoverProbeCheck.canvasHeight)
        .background(OpenMyChrome.canvas)
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 1 }
}
