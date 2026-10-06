import AppKit
import SwiftUI

@main
struct ActivationClickCheck {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let shield = ForegroundActivationClickShield()
        shield.attach(to: window)

        shield.arm()
        precondition(shield.isArmed)
        precondition(shield.hitTest(NSPoint(x: 20, y: 20)) === shield)
        precondition(shield.acceptsFirstMouse(for: nil))

        shield.disarm()
        precondition(!shield.isArmed)
        precondition(shield.hitTest(NSPoint(x: 20, y: 20)) == nil)

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        precondition(shield.isArmed)

        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        // The first activating click must remain shielded for the rest of its
        // dispatch turn. The app disarms asynchronously on the next turn.
        precondition(shield.isArmed)
        shield.disarm()

        shield.detach()
        precondition(shield.superview == nil)

        precondition(DetailHeaderMetrics.leadingPadding(sidebarCollapsed: true) == 154)
        precondition(
            DetailHeaderMetrics.leadingPadding(sidebarCollapsed: false) >= 52,
            "展开左侧栏后系统侧栏钮仍在标题左缘，14 点会叠字"
        )
        precondition(
            DetailHeaderMetrics.leadingPadding(sidebarCollapsed: true)
                > DetailHeaderMetrics.leadingPadding(sidebarCollapsed: false)
        )

        assertPaneHeaderIconButtons()

        print("activation_click_check=passed")
    }

    @MainActor
    private static func assertPaneHeaderIconButtons() {
        precondition(
            PaneHeaderIconMetrics.minHitSize >= 24,
            "图标按钮命中区不得小于 24 点，实际 \(PaneHeaderIconMetrics.minHitSize)"
        )
        precondition(
            PaneHeaderIconMetrics.spacing > 8,
            "三个图标按钮间距必须比原来的 8 点更开，实际 \(PaneHeaderIconMetrics.spacing)"
        )
        precondition(
            PaneHeaderIconMetrics.hoverDelay == 0,
            "悬浮说明必须立即出现，不得走系统 .help 延迟"
        )

        var taps = 0
        let button = Button(action: { taps += 1 }) {
            PaneHeaderIconLabel(
                systemImage: "arrow.up.forward",
                title: "打开原网页"
            )
        }
        .watchGlassButton()
        let host = NSHostingView(rootView: button)
        let collapsedSize = host.fittingSize
        precondition(
            collapsedSize.width >= PaneHeaderIconMetrics.minHitSize
                && collapsedSize.height >= PaneHeaderIconMetrics.minHitSize,
            "图标命中区必须 ≥24×24，实际 \(collapsedSize)"
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: collapsedSize)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        click(window, in: host, at: NSPoint(x: 1, y: host.bounds.height - 1))
        precondition(taps == 1, "点图标左上边缘必须命中，实际 taps=\(taps)")
        click(window, in: host, at: NSPoint(x: host.bounds.width - 1, y: 1))
        precondition(taps == 2, "点图标右下边缘必须命中，实际 taps=\(taps)")
        window.close()

        assertTooltipLayout()
        assertTitlebarTooltipPanel()
    }

    private static func assertTooltipLayout() {
        let host = NSRect(x: 200, y: 400, width: 24, height: 24)
        let tooltip = NSSize(width: 80, height: 22)
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let frame = TitlebarTooltipLayout.panelFrame(
            hostRectOnScreen: host,
            tooltipSize: tooltip,
            visibleFrame: visible
        )
        precondition(frame.size == tooltip)
        precondition(abs(frame.midX - host.midX) < 0.5, "说明应水平居中于按钮，实际 \(frame)")
        precondition(
            abs(frame.maxY - (host.minY - TitlebarTooltipLayout.gap)) < 0.5,
            "说明应贴在按钮正下方，实际 \(frame) 按钮 \(host)"
        )
        precondition(visible.contains(frame))

        let leftHost = NSRect(x: 0, y: 400, width: 24, height: 24)
        let leftFrame = TitlebarTooltipLayout.panelFrame(
            hostRectOnScreen: leftHost,
            tooltipSize: tooltip,
            visibleFrame: visible
        )
        precondition(leftFrame.minX >= visible.minX, "左缘必须钳在可见区域内，实际 \(leftFrame)")

        let bottomHost = NSRect(x: 200, y: 0, width: 24, height: 24)
        let flipped = TitlebarTooltipLayout.panelFrame(
            hostRectOnScreen: bottomHost,
            tooltipSize: tooltip,
            visibleFrame: visible
        )
        precondition(flipped.minY >= visible.minY, "底缘不够时必须上翻，实际 \(flipped)")
        precondition(flipped.minY >= bottomHost.maxY, "上翻后应在按钮上方，实际 \(flipped)")
    }

    @MainActor
    private static func assertTitlebarTooltipPanel() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)

        let root = HStack(spacing: PaneHeaderIconMetrics.spacing) {
            Spacer()
            TitlebarInteractiveHost(tooltip: "打开原网页") {
                hostedIconButton()
            }
            TitlebarInteractiveHost(tooltip: "显示侧栏") {
                hostedIconButton()
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: OpenMyChrome.paneHeaderHeight,
            maxHeight: OpenMyChrome.paneHeaderHeight
        )

        let contentHost = NSHostingView(rootView: root)
        window.contentView = contentHost
        window.makeKeyAndOrderFront(nil)
        pump(window, contentHost)

        let overlays = titlebarOverlays(in: window)
        precondition(overlays.count == 2, "两个图标必须各有一个标题栏宿主，实际 \(overlays.count)")
        let left = overlays[0]
        let right = overlays[1]
        let leftFrame = left.frame
        let rightFrame = right.frame
        precondition(leftFrame.width >= PaneHeaderIconMetrics.minHitSize)
        precondition(rightFrame.width >= PaneHeaderIconMetrics.minHitSize)

        precondition(
            hasHoverTrackingArea(left),
            "左宿主必须有 activeAlways 的 mouseEntered/Exited tracking area"
        )
        precondition(
            hasHoverTrackingArea(right),
            "右宿主必须有 activeAlways 的 mouseEntered/Exited tracking area"
        )

        left.mouseEntered(with: enterExitEvent(.mouseEntered, in: left, window: window))
        pump(window, contentHost)

        precondition(
            abs(left.frame.width - leftFrame.width) < 1
                && abs(left.frame.height - leftFrame.height) < 1,
            "悬停不得改变左宿主 frame，原 \(leftFrame) 现 \(left.frame)"
        )
        precondition(
            abs(right.frame.width - rightFrame.width) < 1
                && abs(right.frame.origin.x - rightFrame.origin.x) < 1,
            "悬停左按钮不得挤占相邻宿主，原 \(rightFrame) 现 \(right.frame)"
        )

        guard let panel = tooltipPanel() else {
            preconditionFailure("mouseEntered 必须立刻 orderFront 无边框说明面板")
        }
        precondition(panel.styleMask.contains(.borderless))
        precondition(panel.styleMask.contains(.nonactivatingPanel))
        precondition(panel.ignoresMouseEvents, "说明面板不得抢走鼠标，否则按钮会 mouseExited")
        precondition(panel.isFloatingPanel)
        precondition(panel.parent === window, "说明面板必须 addChildWindow 挂在主窗口上")
        precondition(panel.frame.width > left.frame.width, "说明面板必须比 24 点图标更宽才能显示中文")
        let expected = TitlebarTooltipLayout.panelFrame(
            hostRectOnScreen: window.convertToScreen(left.convert(left.bounds, to: nil)),
            tooltipSize: panel.frame.size,
            visibleFrame: window.screen?.visibleFrame ?? panel.frame
        )
        precondition(
            abs(panel.frame.minX - expected.minX) < 2
                && abs(panel.frame.minY - expected.minY) < 2,
            "面板位置必须按宿主转屏幕坐标计算，实际 \(panel.frame) 期望 \(expected)"
        )

        left.mouseExited(with: enterExitEvent(.mouseExited, in: left, window: window))
        pump(window, contentHost)
        precondition(!(tooltipPanel()?.isVisible ?? false), "mouseExited 必须立刻 orderOut")
        precondition(
            abs(left.frame.width - leftFrame.width) < 1,
            "移开后宿主宽度仍须保持，实际 \(left.frame.width)"
        )

        window.close()
    }

    private static func hostedIconButton() -> some View {
        Button(action: {}) {
            PaneHeaderIconLabel(
                systemImage: "arrow.up.forward",
                title: "打开原网页"
            )
        }
        .watchGlassButton()
        .accessibilityLabel("打开原网页")
    }

    private static func titlebarOverlays(in window: NSWindow) -> [NSView] {
        guard let frameView = window.contentView?.superview else { return [] }
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if view.accessibilityIdentifier() == "titlebar-interactive-overlay" {
                found.append(view)
            }
            view.subviews.forEach(walk)
        }
        walk(frameView)
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func hasHoverTrackingArea(_ view: NSView) -> Bool {
        view.trackingAreas.contains { area in
            area.options.contains(.mouseEnteredAndExited)
                && area.options.contains(.activeAlways)
                && area.options.contains(.inVisibleRect)
        }
    }

    private static func tooltipPanel() -> NSPanel? {
        NSApp.windows.compactMap { $0 as? NSPanel }.first { panel in
            panel.identifier?.rawValue == "titlebar-tooltip-panel"
        }
    }

    private static func enterExitEvent(
        _ type: NSEvent.EventType,
        in view: NSView,
        window: NSWindow
    ) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type,
            location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            trackingNumber: 0,
            userData: nil
        )!
    }

    private static func pump(_ window: NSWindow, _ host: NSView) {
        for _ in 0..<14 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
        }
    }

    private static func click(_ window: NSWindow, in view: NSView, at local: NSPoint) {
        let location = view.convert(local, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: Int.random(in: 1...10_000),
                clickCount: 1,
                pressure: 1
            )!
        }
        window.sendEvent(event(.leftMouseDown))
        window.sendEvent(event(.leftMouseUp))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
