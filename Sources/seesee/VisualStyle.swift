import AppKit
import SwiftUI

enum PaneHeaderIconMetrics {
    static let minHitSize: CGFloat = 24
    static let spacing: CGFloat = 12
    static let hoverDelay: TimeInterval = 0
}

struct PaneHeaderIconLabel: View {
    let systemImage: String
    let title: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .frame(
                minWidth: PaneHeaderIconMetrics.minHitSize,
                minHeight: PaneHeaderIconMetrics.minHitSize
            )
            .contentShape(Rectangle())
            .accessibilityLabel(title)
    }
}

enum TitlebarTooltipLayout {
    static let gap: CGFloat = 4

    static func panelFrame(
        hostRectOnScreen: NSRect,
        tooltipSize: NSSize,
        visibleFrame: NSRect,
        gap: CGFloat = gap
    ) -> NSRect {
        var frame = NSRect(
            x: hostRectOnScreen.midX - tooltipSize.width / 2,
            y: hostRectOnScreen.minY - gap - tooltipSize.height,
            width: tooltipSize.width,
            height: tooltipSize.height
        )
        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
        }
        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
        }
        if frame.minY < visibleFrame.minY {
            frame.origin.y = hostRectOnScreen.maxY + gap
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = visibleFrame.maxY - frame.height
        }
        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
        }
        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
        }
        return frame
    }
}

struct TitlebarTooltipChrome: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(OpenMyChrome.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .watchGlass(
                .regular,
                in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous)
            )
            .fixedSize()
    }
}

enum DetailHeaderMetrics {
    static let collapsedLeadingPadding: CGFloat = 154
    static let expandedLeadingPadding: CGFloat = 56

    /// 收起时要让过红绿灯和系统侧栏钮；展开后红绿灯进左栏，侧栏钮仍停在标题左缘。
    static func leadingPadding(sidebarCollapsed: Bool) -> CGFloat {
        sidebarCollapsed ? collapsedLeadingPadding : expandedLeadingPadding
    }
}

enum WatchGlassStyle {
    case regular
    case clear
}

extension View {
    func watchGlass<S: InsettableShape>(
        _ style: WatchGlassStyle = .regular,
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        modifier(WatchGlassModifier(style: style, tint: tint, interactive: interactive, shape: shape))
    }

    func watchGlassButton(prominent: Bool = false) -> some View {
        modifier(WatchGlassButtonModifier(prominent: prominent))
    }
}

private struct WatchGlassModifier<S: InsettableShape>: ViewModifier {
    let style: WatchGlassStyle
    let tint: Color?
    let interactive: Bool
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        let fill = tint ?? (style == .clear ? OpenMyChrome.canvas : OpenMyChrome.raise)
        content
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(OpenMyChrome.hair)
            }
    }
}

private struct WatchGlassButtonModifier: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        content.buttonStyle(OpenMyChromeButtonStyle(prominent: prominent))
    }
}

private struct OpenMyChromeButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? OpenMyChrome.canvas : OpenMyChrome.ink)
            .background(
                prominent ? OpenMyChrome.ink : OpenMyChrome.raise,
                in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusMd, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: OpenMyChrome.radiusMd, style: .continuous)
                    .strokeBorder(OpenMyChrome.hair)
            }
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct WatchGlassContainer<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        content
    }
}

enum WindowChromeMetrics {
    static let minimumSize = NSSize(width: 980, height: 640)

    static func clamp(_ size: NSSize) -> NSSize {
        NSSize(
            width: max(size.width, minimumSize.width),
            height: max(size.height, minimumSize.height)
        )
    }

    /// 最小尺寸必须写在窗口上。SwiftUI 布局之后会用自己的 contentMinSize 覆盖
    /// NSWindow.minSize，所以每次配置和尺寸变化都要重新断言。
    static func applyMinimumSize(to window: NSWindow) {
        window.minSize = minimumSize
        window.contentMinSize = minimumSize
        guard window.frame.width + 0.5 < minimumSize.width
            || window.frame.height + 0.5 < minimumSize.height else { return }
        var frame = window.frame
        let repairedHeight = max(frame.height, minimumSize.height)
        frame.origin.y -= repairedHeight - frame.height
        frame.size.width = max(frame.width, minimumSize.width)
        frame.size.height = repairedHeight
        window.setFrame(frame, display: true, animate: false)
    }
}

/// 转发原窗口代理，并在用户拖拽时钳制最小尺寸。
final class WindowMinSizeGuard: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private weak var observedWindow: NSWindow?

    func install(on window: NSWindow) {
        if observedWindow === window, window.delegate === self { return }
        if window.delegate !== self {
            original = window.delegate
        }
        observedWindow = window
        window.delegate = self
    }

    func detach() {
        if let window = observedWindow, window.delegate === self {
            window.delegate = original
        }
        observedWindow = nil
        original = nil
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        sender.minSize = WindowChromeMetrics.minimumSize
        sender.contentMinSize = WindowChromeMetrics.minimumSize
        var size = WindowChromeMetrics.clamp(frameSize)
        if let original, original.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))) {
            size = WindowChromeMetrics.clamp(original.windowWillResize?(sender, to: size) ?? size)
        }
        return size
    }
}

struct WindowStyleConfigurator: NSViewRepresentable {
    let title: String

    final class Coordinator {
        private let trafficLightVerticalOffset: CGFloat = 8
        private let sidebarToggleVerticalOffset: CGFloat = 4
        weak var alignedWindow: NSWindow?
        let activationClickShield = ForegroundActivationClickShield()
        let windowFocusController = PlaybackWindowFocusController()
        let minSizeGuard = WindowMinSizeGuard()
        private var resizeObserver: NSObjectProtocol?

        func centerTrafficLights(in window: NSWindow) {
            guard alignedWindow !== window else { return }
            alignedWindow = window

            // The app extends its 56-point pane headers through the native
            // title-bar region. AppKit positions the traffic lights for its
            // shorter default title bar, so lower the cluster to the visual
            // center shared by the URL field and the adjacent pane headers.
            for buttonType in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ] {
                guard let button = window.standardWindowButton(buttonType) else { continue }
                var frame = button.frame
                frame.origin.y -= trafficLightVerticalOffset
                button.setFrameOrigin(frame.origin)
            }
        }

        func alignSidebarToggle(in window: NSWindow) {
            // NavigationSplitView's native toggle is rendered by a private
            // SwiftUI toolbar host while NSToolbarItem.view remains nil. Move
            // that host through its existing center-Y constraint so AppKit's
            // later layout passes preserve both the visual and hit target.
            guard let root = window.contentView?.superview,
                  let itemView = sidebarToggleHostingView(in: root),
                  let container = itemView.superview,
                  let centerYConstraint = container.constraints.first(where: {
                      ($0.firstItem as AnyObject?) === itemView &&
                      $0.firstAttribute == .centerY &&
                      ($0.secondItem as AnyObject?) === container &&
                      $0.secondAttribute == .centerY
                  }) else { return }

            let alignedConstant = sidebarToggleVerticalOffset
            guard centerYConstraint.constant != alignedConstant else { return }
            centerYConstraint.constant = alignedConstant
            container.layoutSubtreeIfNeeded()
        }

        private func sidebarToggleHostingView(in view: NSView) -> NSView? {
            if view.className.contains("ToolbarItemHostingView"),
               view.superview?.className == "NSToolbarItemViewer" {
                return view
            }
            for subview in view.subviews {
                if let match = sidebarToggleHostingView(in: subview) {
                    return match
                }
            }
            return nil
        }

        func scheduleSidebarToggleAlignment(in window: NSWindow) {
            for delay in [0.0, 0.05, 0.15, 0.3, 0.75, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.alignSidebarToggle(in: window)
                }
            }
        }

        func attachMinimumSize(to window: NSWindow) {
            minSizeGuard.install(on: window)
            WindowChromeMetrics.applyMinimumSize(to: window)
            guard resizeObserver == nil else { return }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                WindowChromeMetrics.applyMinimumSize(to: window)
            }
        }

        func detach() {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            resizeObserver = nil
            minSizeGuard.detach()
            activationClickShield.detach()
            windowFocusController.detach()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        // The center-pane actions live inside the full-size title-bar region.
        // Treating all SwiftUI content as draggable background lets AppKit
        // consume their mouse-down events before Button and Menu receive them.
        // The standard title bar remains available for moving the window.
        window.isMovableByWindowBackground = false
        OpenMyChrome.applyWindowChrome(window)
        coordinator.centerTrafficLights(in: window)
        coordinator.scheduleSidebarToggleAlignment(in: window)
        coordinator.activationClickShield.attach(to: window)
        coordinator.windowFocusController.attach(to: window)
        coordinator.attachMinimumSize(to: window)
    }
}

/// SwiftUI controls in a full-size title bar can accept the same mouse-down
/// event that activates an inactive window. Keep a transparent shield above
/// the whole window while the app is in the background so that first click is
/// activation-only; later clicks pass through normally once the app is active.
final class ForegroundActivationClickShield: NSView {
    private weak var protectedWindow: NSWindow?
    private var activationObservers: [NSObjectProtocol] = []
    private(set) var isArmed = false

    func attach(to window: NSWindow) {
        guard protectedWindow !== window || superview == nil else { return }
        detach()
        guard let windowFrameView = window.contentView?.superview else { return }

        protectedWindow = window
        frame = windowFrameView.bounds
        autoresizingMask = [.width, .height]
        windowFrameView.addSubview(self, positioned: .above, relativeTo: nil)

        activationObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                self?.arm()
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                // A click that activates the app is still being dispatched
                // when this notification arrives. Keep the shield armed until
                // the next main-loop turn so that click cannot reach a control.
                DispatchQueue.main.async {
                    self?.disarm()
                }
            }
        ]

        if NSApp.isActive {
            disarm()
        } else {
            arm()
        }
    }

    func detach() {
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObservers.removeAll()
        isArmed = false
        protectedWindow = nil
        removeFromSuperview()
    }

    func arm() {
        isArmed = true
        // Title-bar controls are hosted in sibling overlays. Reinsert the
        // shield whenever the app resigns active so it remains above them too.
        guard let container = superview else { return }
        removeFromSuperview()
        container.addSubview(self, positioned: .above, relativeTo: nil)
    }

    func disarm() {
        isArmed = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isArmed ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        activateWithoutForwardingClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        activateWithoutForwardingClick()
    }

    override func otherMouseDown(with event: NSEvent) {
        activateWithoutForwardingClick()
    }

    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}

    private func activateWithoutForwardingClick() {
        guard isArmed else { return }
        NSApp.activate(ignoringOtherApps: true)
        protectedWindow?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.disarm()
        }
    }

    deinit {
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// Reports the real NSWindow width. A GeometryReader attached to a
/// NavigationSplitView can inherit a column's proposed size during its own
/// visibility transition, which makes it an unreliable source for deciding
/// whether two side panes fit.
struct WindowWidthReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WindowWidthTrackingView {
        let view = WindowWidthTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowWidthTrackingView, context: Context) {
        view.onChange = onChange
        view.reportWidth()
    }
}

final class WindowWidthTrackingView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var resizeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.reportWidth()
        }
        reportWidth()
    }

    func reportWidth() {
        guard let width = window?.frame.width else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(width)
        }
    }

    private func stopObserving() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = nil
    }

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }
}

/// SwiftUI can draw into a full-size title bar while AppKit's toolbar remains
/// above it in the window hierarchy. This host preserves SwiftUI's layout with
/// an invisible marker, then constrains the interactive content directly to
/// that marker above the toolbar so it follows pane and window layout changes.
private final class TitlebarHostingView<Content: View>: NSHostingView<Content> {
    var tooltipText = "" {
        didSet {
            guard oldValue != tooltipText else { return }
            updateTrackingAreas()
            if tooltipText.isEmpty {
                hideTooltip()
            }
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var tooltipPanel: NSPanel?
    private var tooltipContent: NSHostingView<TitlebarTooltipChrome>?

    // NSThemeFrame advertises the native title-bar safe area to descendants.
    // This detached overlay already lives inside that area, so inheriting it
    // would add 52 points to its fitting height and clip the real controls.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        guard !tooltipText.isEmpty else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        showTooltip()
    }

    override func mouseExited(with event: NSEvent) {
        hideTooltip()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hideTooltip()
        }
    }

    func repositionTooltipIfNeeded() {
        guard tooltipPanel?.isVisible == true else { return }
        tooltipPanel?.setFrame(currentTooltipFrame(), display: true)
    }

    func dismissTooltip() {
        hideTooltip()
        tooltipPanel?.close()
        tooltipPanel = nil
        tooltipContent = nil
    }

    private func showTooltip() {
        guard !tooltipText.isEmpty, window != nil else { return }
        let panel = tooltipPanel ?? makePanel()
        tooltipPanel = panel
        let content = tooltipContent ?? NSHostingView(rootView: TitlebarTooltipChrome(text: tooltipText))
        content.rootView = TitlebarTooltipChrome(text: tooltipText)
        let size = content.fittingSize
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content
        tooltipContent = content
        panel.setContentSize(size)
        panel.setFrame(currentTooltipFrame(), display: true)
        if let window, panel.parent !== window {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.level = .floating
        panel.orderFront(nil)
    }

    private func hideTooltip() {
        guard let panel = tooltipPanel else { return }
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }

    private func currentTooltipFrame() -> NSRect {
        let hostOnScreen = window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
        let size = tooltipContent?.fittingSize
            ?? NSHostingView(rootView: TitlebarTooltipChrome(text: tooltipText)).fittingSize
        let visible = window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? hostOnScreen
        return TitlebarTooltipLayout.panelFrame(
            hostRectOnScreen: hostOnScreen,
            tooltipSize: size,
            visibleFrame: visible
        )
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 40, height: 20)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityIdentifier("titlebar-tooltip-panel")
        panel.identifier = NSUserInterfaceItemIdentifier("titlebar-tooltip-panel")
        return panel
    }

    deinit {
        tooltipPanel?.close()
        tooltipPanel = nil
    }
}

struct TitlebarInteractiveHost<Content: View>: NSViewRepresentable {
    var tooltip: String
    private let content: Content

    init(tooltip: String = "", @ViewBuilder content: () -> Content) {
        self.tooltip = tooltip
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content, tooltip: tooltip)
    }

    func makeNSView(context: Context) -> TitlebarInteractiveMarkerView {
        let marker = TitlebarInteractiveMarkerView()
        context.coordinator.attach(to: marker)
        return marker
    }

    func updateNSView(_ marker: TitlebarInteractiveMarkerView, context: Context) {
        context.coordinator.update(content: content, tooltip: tooltip)
    }

    static func dismantleNSView(
        _ marker: TitlebarInteractiveMarkerView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    final class Coordinator {
        private let hostingView: TitlebarHostingView<AnyView>
        private weak var marker: TitlebarInteractiveMarkerView?
        private weak var observedWindow: NSWindow?
        private var windowResizeObserver: NSObjectProtocol?
        private var layoutObservers: [NSObjectProtocol] = []

        init(content: Content, tooltip: String) {
            hostingView = TitlebarHostingView(rootView: Self.hosted(content))
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            hostingView.setAccessibilityIdentifier("titlebar-interactive-overlay")
            hostingView.tooltipText = tooltip
        }

        func attach(to marker: TitlebarInteractiveMarkerView) {
            self.marker = marker
            marker.intrinsicSizeProvider = { [weak self] in
                self?.hostingView.fittingSize ?? .zero
            }
            marker.windowHandler = { [weak self] in
                self?.installHostingView()
            }
            marker.layoutHandler = { [weak self] in
                self?.scheduleOverlayFrameUpdate()
            }
            marker.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in
                self?.installHostingView()
            }
        }

        func update(content: Content, tooltip: String) {
            hostingView.tooltipText = tooltip
            hostingView.rootView = Self.hosted(content)
            hostingView.invalidateIntrinsicContentSize()
            marker?.invalidateIntrinsicContentSize()
            scheduleOverlayFrameUpdate()
        }

        func detach() {
            marker?.windowHandler = nil
            marker?.intrinsicSizeProvider = nil
            marker?.layoutHandler = nil
            stopObservingWindow()
            hostingView.dismissTooltip()
            hostingView.removeFromSuperview()
            marker = nil
        }

        private func installHostingView() {
            guard let marker,
                  let window = marker.window,
                  let windowFrameView = window.contentView?.superview else {
                stopObservingWindow()
                hostingView.removeFromSuperview()
                return
            }

            if hostingView.superview !== windowFrameView {
                hostingView.removeFromSuperview()
                windowFrameView.addSubview(hostingView, positioned: .above, relativeTo: nil)
                hostingView.translatesAutoresizingMaskIntoConstraints = true
                hostingView.invalidateIntrinsicContentSize()
                marker.invalidateIntrinsicContentSize()
            }
            observeWindowIfNeeded(window)
            observeLayoutChain(from: marker, through: windowFrameView)
            updateOverlayFrame()
            scheduleOverlayFrameUpdatesThroughAnimation()
        }

        private func observeWindowIfNeeded(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            stopObservingWindow()
            observedWindow = window
            windowResizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleOverlayFrameUpdate()
            }
        }

        private func stopObservingWindow() {
            if let windowResizeObserver {
                NotificationCenter.default.removeObserver(windowResizeObserver)
            }
            windowResizeObserver = nil
            observedWindow = nil
            stopObservingLayoutChain()
        }

        private func observeLayoutChain(from marker: NSView, through windowFrameView: NSView) {
            stopObservingLayoutChain()

            var view: NSView? = marker
            while let current = view {
                current.postsFrameChangedNotifications = true
                current.postsBoundsChangedNotifications = true

                for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                    layoutObservers.append(
                        NotificationCenter.default.addObserver(
                            forName: name,
                            object: current,
                            queue: .main
                        ) { [weak self] _ in
                            self?.scheduleOverlayFrameUpdate()
                        }
                    )
                }

                if current === windowFrameView { break }
                view = current.superview
            }
        }

        private func stopObservingLayoutChain() {
            for observer in layoutObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            layoutObservers.removeAll()
        }

        private func scheduleOverlayFrameUpdate() {
            DispatchQueue.main.async { [weak self] in
                self?.updateOverlayFrame()
            }
        }

        /// Split-view visibility transitions can move an entire ancestor chain
        /// without resizing the window or relaying out the marker itself. Keep
        /// the overlay attached throughout the short system animation, with a
        /// final pass after it settles to avoid retaining an intermediate frame.
        private func scheduleOverlayFrameUpdatesThroughAnimation() {
            for delay in [0.0, 0.05, 0.12, 0.22, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.updateOverlayFrame()
                }
            }
        }

        private func updateOverlayFrame() {
            guard let marker,
                  let window = marker.window,
                  let windowFrameView = window.contentView?.superview,
                  hostingView.superview === windowFrameView else { return }
            let markerAnchorFrame = marker.convert(marker.bounds, to: windowFrameView)
            let fittingSize = hostingView.fittingSize
            guard fittingSize.width > 0, fittingSize.height > 0 else { return }
            var markerFrame = NSRect(
                x: markerAnchorFrame.maxX - fittingSize.width,
                y: markerAnchorFrame.minY,
                width: fittingSize.width,
                height: fittingSize.height
            )
            // Every pane uses the same 56-point title row. Anchor the hosted
            // control to the visible NSWindow frame instead of compensating
            // for marker safe areas or NSThemeFrame bounds, both of which can
            // change across window states. Horizontal placement remains
            // entirely marker-driven.
            let titleRowHeight = OpenMyChrome.paneHeaderHeight
            let verticalInset = (titleRowHeight - markerFrame.height) / 2
            let controlBottomOnScreen = window.frame.maxY - verticalInset - markerFrame.height
            let controlBottomInWindow = window.convertPoint(
                fromScreen: NSPoint(x: window.frame.minX, y: controlBottomOnScreen)
            )
            markerFrame.origin.y = windowFrameView.convert(controlBottomInWindow, from: nil).y
            if hostingView.frame != markerFrame {
                hostingView.frame = markerFrame
            }
            hostingView.repositionTooltipIfNeeded()
        }

        private static func hosted(_ content: Content) -> AnyView {
            AnyView(
                // This host also supplies the marker's intrinsic size. Asking
                // for infinite space here creates a feedback loop with the
                // split view during live window resizing: the title-bar item
                // remembers the old pane width and prevents the detail pane
                // from shrinking. Title-bar controls are intrinsically sized,
                // so keep the bridge at that compact size and let the live
                // marker frame position it.
                content.fixedSize()
            )
        }
    }
}

final class TitlebarInteractiveMarkerView: NSView {
    var intrinsicSizeProvider: (() -> NSSize)?
    var windowHandler: (() -> Void)?
    var layoutHandler: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        intrinsicSizeProvider?() ?? .zero
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.windowHandler?()
        }
    }

    override func layout() {
        super.layout()
        layoutHandler?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
enum ThumbnailImageCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
