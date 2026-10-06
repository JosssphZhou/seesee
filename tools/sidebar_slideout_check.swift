import AppKit
import Foundation
import SwiftUI

/// 编译真实 ContentView 时排除了带 @main 的 SeeseeApp，这里补回 AppDelegate 引用的开窗入口。
@MainActor
enum MainWindowOpener {
    static let sceneID = "main"
    static var open: (() -> Void)?
}

private struct Sample {
    var tMS: Int
    var windowFrame: CGRect
    var contentFrame: CGRect
    var contentBounds: CGRect
    var fittingSize: CGSize
    var sidebarFrame: CGRect
    var detailFrame: CGRect
    var scaleX: CGFloat
    var scaleY: CGFloat
}

@main
struct SidebarSlideoutCheck {
    static let windowWidth: CGFloat = 1000
    static let windowHeight: CGFloat = 640
    static let sampleInterval: TimeInterval = 0.05
    static let sampleCount = 21
    static let contactPath = "/tmp/sidebar-slideout-contact.png"
    static let logPath = "/tmp/sidebar-slideout-frames.log"

    @MainActor
    static func main() {
        // 本检查以进程名为偏好域：清掉上一轮留下的栏位状态，保证每次从同一初始态开始。
        UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
        setvbuf(stdout, nil, _IONBF, 0)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        OpenMyChrome.applyAppearance()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seesee-sidebar-slideout-\(UUID().uuidString)", isDirectory: true)
        let mediaFolder = root.appendingPathComponent("media", isDirectory: true)
        let dataFile = root.appendingPathComponent("queue.json")
        try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let itemID = UUID()
        let item = WatchItem(
            id: itemID,
            urlString: "https://example.com/sidebar-slideout",
            title: "侧栏滑出复现",
            author: "check",
            duration: 120,
            addedAt: Date(),
            watchedAt: nil,
            state: .ready,
            progress: 1,
            progressLabel: "已完成",
            localFilePath: nil,
            errorMessage: nil,
            playbackPosition: 0,
            chapters: [VideoChapter(title: "开场", startTime: 0, endTime: 30)],
            thumbnailFilePath: nil,
            subtitleFilePath: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try! encoder.encode([item]).write(to: dataFile)

        UserDefaults.standard.set(false, forKey: "chaptersPresented")
        UserDefaults.standard.set(false, forKey: "sidebarWatchedCollapsed")

        let store = QueueStore(dataFile: dataFile, mediaFolder: mediaFolder)
        store.selection = itemID
        let inbox = URLInbox()

        let window = NSWindow(
            contentRect: NSRect(x: -4800, y: -4800, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: windowWidth, height: windowHeight))

        let controller = NSHostingController(
            rootView: ContentView()
                .environmentObject(store)
                .environmentObject(inbox)
                .preferredColorScheme(.dark)
                .tint(OpenMyChrome.ink)
        )
        controller.view.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        let host = controller.view
        window.orderBack(nil)

        pump(window, host, times: 16)
        pinNarrowWindow(window)
        pump(window, host, times: 8)
        pinNarrowWindow(window)

        disarmClickShield(in: window.contentView?.superview ?? host)
        let mounted = measure(window, host: host, tMS: -2)
        print("mounted window=\(fmt(mounted.windowFrame)) content=\(fmt(mounted.contentFrame)) sidebar=\(fmt(mounted.sidebarFrame)) fitting=\(fmt(mounted.fittingSize))")

        if mounted.sidebarFrame.width >= 40 {
            collapseLeadingSidebar(in: window, host: host)
            waitUntil(timeout: 1.2) {
                pinNarrowWindow(window)
                disarmClickShield(in: window.contentView?.superview ?? host)
                return measure(window, host: host, tMS: 0).sidebarFrame.width < 40
            }
        }

        pinNarrowWindow(window)
        // 窄窗自动收起左栏经 onChange 与动画完成，机器忙时不止 1.2 秒：等到收起为止，最多 8 秒。
        for _ in 0..<160 where measure(window, host: host, tMS: -1).sidebarFrame.width >= 40 {
            pump(window, host, times: 1)
        }
        let collapsed = measure(window, host: host, tMS: -1)
        print("collapsed window=\(fmt(collapsed.windowFrame)) content=\(fmt(collapsed.contentFrame)) sidebar=\(fmt(collapsed.sidebarFrame)) detail=\(fmt(collapsed.detailFrame)) fitting=\(fmt(collapsed.fittingSize))")
        precondition(
            collapsed.sidebarFrame.width < 40,
            "点滑出前左栏必须已收起，实际 \(fmt(collapsed.sidebarFrame)) window=\(fmt(collapsed.windowFrame))"
        )
        let startWindow = collapsed.windowFrame

        disarmClickShield(in: window.contentView?.superview ?? host)
        expandLeadingSidebar(in: window, host: host)
        var samples: [Sample] = []
        var images: [NSBitmapImageRep] = []
        for index in 0..<sampleCount {
            if index > 0 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: sampleInterval))
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
            }
            let sample = measure(window, host: host, tMS: index * 50)
            samples.append(sample)
            images.append(capture(window))
            log(sample)
        }

        writeContactSheet(images)
        writeLog(samples)

        let undersized = NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: 600, height: 400)
        print(
            "min_size_before setFrame=600x400 minSize=\(fmt(window.minSize)) contentMinSize=\(fmt(window.contentMinSize)) frame=\(fmt(window.frame))"
        )
        window.setFrame(undersized, display: true, animate: false)
        pump(window, host, times: 8)
        print(
            "min_size_after setFrame=600x400 minSize=\(fmt(window.minSize)) contentMinSize=\(fmt(window.contentMinSize)) frame=\(fmt(window.frame))"
        )
        precondition(
            window.frame.width + 0.5 >= 980 && window.frame.height + 0.5 >= 640,
            "窗口 setFrame 到 600×400 后宽高不得小于 980×640，实际 \(fmt(window.frame))"
        )

        window.close()

        let final = samples[samples.count - 1]
        let uniqueWindows = Set(samples.map { roundRect($0.windowFrame) })
        let playerGrew = samples.contains {
            $0.detailFrame.width > collapsed.detailFrame.width + 8
                || $0.detailFrame.height > collapsed.detailFrame.height + 8
        }
        let scaled = samples.contains { $0.scaleX > 1.04 || $0.scaleY > 1.04 }
        // 滑入动画约 0.22 秒，fittingSize 瞬时偏高可以接受；动画结束后必须回到窗口宽。
        let settled = samples.filter { $0.tMS >= 250 }
        let contentOverflowed = settled.contains {
            $0.contentBounds.width > startWindow.width + 8
                || $0.fittingSize.width > startWindow.width + 40
        }

        print(
            "sidebar_slideout_check contact=\(contactPath) log=\(logPath) start=\(fmt(startWindow)) final_sidebar=\(fmt(final.sidebarFrame)) unique_window_frames=\(uniqueWindows.count) player_grew=\(playerGrew) scaled=\(scaled) overflow=\(contentOverflowed)"
        )

        precondition(
            final.sidebarFrame.width >= 200,
            "展开后左侧栏必须留下，最终 \(fmt(final.sidebarFrame))"
        )
        precondition(
            uniqueWindows.count <= 2,
            "窗口 frame 变化不得超过一次，实际 \(uniqueWindows.count) 种：\(uniqueWindows.sorted())"
        )
        precondition(
            abs(final.windowFrame.width - startWindow.width) < 2
                && abs(final.windowFrame.height - startWindow.height) < 2,
            "窗口尺寸不得跳变，起始 \(fmt(startWindow)) 最终 \(fmt(final.windowFrame))"
        )
        precondition(
            !playerGrew && !scaled && !contentOverflowed,
            "播放区必须收窄而不得放大。player_grew=\(playerGrew) scaled=\(scaled) overflow=\(contentOverflowed)"
        )
        assertMonotonicShrink(samples, initial: collapsed.detailFrame)

        print("sidebar_slideout_check=passed")
    }

    @MainActor
    private static func pinNarrowWindow(_ window: NSWindow) {
        window.setContentSize(NSSize(width: windowWidth, height: windowHeight))
        var frame = window.frame
        // 放在主屏可见区内（alpha 为 0 看不见）：完全离屏的窗口不会布局与动画，收起动作永远不完成。
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        frame.origin = NSPoint(x: visible.minX, y: visible.minY)
        window.setFrame(frame, display: true, animate: false)
    }

    @MainActor
    private static func collapseLeadingSidebar(in window: NSWindow, host: NSView) {
        toggleLeadingSidebar(in: window, host: host, shouldExpand: false)
    }

    @MainActor
    private static func expandLeadingSidebar(in window: NSWindow, host: NSView) {
        toggleLeadingSidebar(in: window, host: host, shouldExpand: true)
    }

    @MainActor
    private static func toggleLeadingSidebar(in window: NSWindow, host: NSView, shouldExpand: Bool) {
        let matches: (CGFloat) -> Bool = { width in
            shouldExpand ? width >= 40 : width < 40
        }
        // 先走与菜单「显示或隐藏左侧栏」相同的通知（确定性），点击工具栏按钮只作后备。
        NotificationCenter.default.post(name: .seeseeSidebarToggle, object: nil, userInfo: ["collapsed": !shouldExpand])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        if matches(measure(window, host: host, tMS: 0).sidebarFrame.width) { return }
        let clicked = clickSidebarToggle(in: window)
        if clicked {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
            if matches(measure(window, host: host, tMS: 0).sidebarFrame.width) { return }
        }
        // 点击没落到工具栏按钮时（进程不活跃、窗口不是 key），直接对分栏控制器做与按钮相同的动作。
        var sent = NSApp.sendAction(NSSelectorFromString("toggleSidebar:"), to: nil, from: window)
        if !sent, let split = window.contentViewController.flatMap(splitViewController(in:)) {
            split.toggleSidebar(nil)
            sent = true
        }
        if !sent, let toolbar = window.toolbar {
            // 直接触发工具栏里「隐藏边栏」项的动作，与用户点击等价。
            for item in toolbar.items {
                let identifier = item.itemIdentifier.rawValue.lowercased()
                guard identifier.contains("togglesidebar") else { continue }
                if let action = item.action, NSApp.sendAction(action, to: item.target, from: item) {
                    sent = true
                    break
                }
                if let view = item.view, let control = firstControl(in: view) {
                    control.performClick(nil)
                    sent = true
                    break
                }
                if let view = item.view {
                    print("toggleSidebar 项视图层级: \(describe(view))")
                }
            }
            if !sent {
                print("toolbar items: \(toolbar.items.map { $0.itemIdentifier.rawValue })")
            }
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        let width = measure(window, host: host, tMS: 0).sidebarFrame.width
        print("toggleLeadingSidebar clicked=\(clicked) sent=\(sent) width=\(width)")
        if matches(width) { return }
    }

    private static func disarmClickShield(in view: NSView) {
        if let shield = view as? ForegroundActivationClickShield {
            shield.disarm()
        }
        for child in view.subviews {
            disarmClickShield(in: child)
        }
    }

    @MainActor
    private static func measure(
        _ window: NSWindow,
        host: NSView,
        tMS: Int
    ) -> Sample {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let sidebar = leadingColumnFrame(in: host)
        let transform = host.layer?.affineTransform() ?? .identity
        return Sample(
            tMS: tMS,
            windowFrame: window.frame,
            contentFrame: host.frame,
            contentBounds: host.bounds,
            fittingSize: host.fittingSize,
            sidebarFrame: sidebar,
            detailFrame: detailFrame(in: host, sidebar: sidebar),
            scaleX: transform.a,
            scaleY: transform.d
        )
    }

    private static func leadingColumnFrame(in host: NSView) -> CGRect {
        var best = CGRect.zero
        func walk(_ view: NSView) {
            if view.isHidden { return }
            let frame = view.convert(view.bounds, to: host)
            if frame.minX <= 4,
               frame.width >= 200,
               frame.width <= 400,
               frame.height > host.bounds.height * 0.45 {
                if frame.width > best.width {
                    best = frame
                }
            }
            for child in view.subviews {
                walk(child)
            }
        }
        walk(host)
        return best
    }

    private static func detailFrame(in host: NSView, sidebar: CGRect) -> CGRect {
        if sidebar.width >= 8 {
            return CGRect(
                x: sidebar.maxX,
                y: 0,
                width: max(0, host.bounds.width - sidebar.maxX),
                height: host.bounds.height
            )
        }
        return host.bounds
    }

    private static func clickSidebarToggle(in window: NSWindow) -> Bool {
        guard let root = window.contentView?.superview,
              let itemView = sidebarToggleHostingView(in: root) else { return false }
        let location = itemView.convert(
            NSPoint(x: itemView.bounds.midX, y: itemView.bounds.midY),
            to: nil
        )
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
        return true
    }

    private static func firstControl(in view: NSView) -> NSControl? {
        if let control = view as? NSControl { return control }
        for child in view.subviews {
            if let found = firstControl(in: child) { return found }
        }
        return nil
    }

    private static func describe(_ view: NSView, depth: Int = 0) -> String {
        let line = String(repeating: " ", count: depth) + view.className
        return ([line] + view.subviews.map { describe($0, depth: depth + 1) }).joined(separator: "\n")
    }

    private static func splitViewController(in controller: NSViewController) -> NSSplitViewController? {
        if let split = controller as? NSSplitViewController { return split }
        for child in controller.children {
            if let found = splitViewController(in: child) { return found }
        }
        return nil
    }

    private static func sidebarToggleHostingView(in view: NSView) -> NSView? {
        if view.className.contains("ToolbarItemHostingView"),
           view.superview?.className == "NSToolbarItemViewer" {
            return view
        }
        for child in view.subviews {
            if let found = sidebarToggleHostingView(in: child) {
                return found
            }
        }
        return nil
    }

    @MainActor
    private static func pump(_ window: NSWindow, _ host: NSView, times: Int) {
        for _ in 0..<times {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private static func capture(_ window: NSWindow) -> NSBitmapImageRep {
        let target = window.contentView?.superview ?? window.contentView!
        let size = target.bounds.size
        let pixelsWide = max(1, Int(size.width.rounded()))
        let pixelsHigh = max(1, Int(size.height.rounded()))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        target.cacheDisplay(in: target.bounds, to: rep)
        return rep
    }

    private static func writeContactSheet(_ images: [NSBitmapImageRep]) {
        let columns = 7
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let cellWidth = 160
        let cellHeight = 102
        let sheet = NSImage(
            size: NSSize(width: columns * cellWidth, height: rows * cellHeight)
        )
        sheet.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: sheet.size.width, height: sheet.size.height).fill()
        for (index, image) in images.enumerated() {
            let column = index % columns
            let row = index / columns
            let dest = NSRect(
                x: column * cellWidth,
                y: Int(sheet.size.height) - (row + 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            image.draw(in: dest)
        }
        sheet.unlockFocus()
        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("sidebar_slideout_check: 无法编码拼图")
        }
        try! png.write(to: URL(fileURLWithPath: contactPath))
    }

    private static func writeLog(_ samples: [Sample]) {
        let lines = samples.map { sample in
            "t=\(sample.tMS)ms window=\(fmt(sample.windowFrame)) content=\(fmt(sample.contentFrame)) bounds=\(fmt(sample.contentBounds)) fitting=\(fmt(sample.fittingSize)) sidebar=\(fmt(sample.sidebarFrame)) detail=\(fmt(sample.detailFrame)) scale=(\(round1(sample.scaleX)),\(round1(sample.scaleY)))"
        }
        try! (lines.joined(separator: "\n") + "\n")
            .write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    private static func log(_ sample: Sample) {
        print(
            "t=\(sample.tMS)ms window=\(fmt(sample.windowFrame)) content=\(fmt(sample.contentFrame)) sidebar=\(fmt(sample.sidebarFrame)) detail=\(fmt(sample.detailFrame)) fitting=\(fmt(sample.fittingSize)) scale=(\(round1(sample.scaleX)),\(round1(sample.scaleY)))"
        )
    }

    private static func assertMonotonicShrink(_ samples: [Sample], initial: CGRect) {
        var previous = initial.width
        for sample in samples {
            precondition(
                sample.detailFrame.width <= previous + 12,
                "播放区宽度必须单调收窄。t=\(sample.tMS)ms 上一帧 \(previous) 当前 \(sample.detailFrame.width)"
            )
            previous = min(previous, sample.detailFrame.width)
        }
    }

    private static func roundRect(_ rect: CGRect) -> String {
        "\(Int(rect.origin.x.rounded()))x\(Int(rect.origin.y.rounded()))x\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }

    private static func fmt(_ rect: CGRect) -> String {
        "(\(round1(rect.origin.x)),\(round1(rect.origin.y)),\(round1(rect.width)),\(round1(rect.height)))"
    }

    private static func fmt(_ size: CGSize) -> String {
        "(\(round1(size.width)),\(round1(size.height)))"
    }

    private static func round1(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}
