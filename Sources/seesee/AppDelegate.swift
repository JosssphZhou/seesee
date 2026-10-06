import AppKit
import Foundation

@MainActor
final class URLInbox: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published private(set) var clipboardValues: [String] = []

    func receive(_ incoming: [URL]) {
        urls.append(contentsOf: incoming)
    }

    func receiveClipboard(_ value: String) {
        clipboardValues.append(value)
    }

    func clear() {
        urls.removeAll()
    }

    func clearClipboard() {
        clipboardValues.removeAll()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let inbox = URLInbox()
    private var pasteMonitor: Any?
    private var mediaKeyMonitor: Any?
    private var agentLink: AgentLinkServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        OpenMyChrome.applyAppearance()
        SystemMediaController.shared.start()
        startAgentLink()
        mediaKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { event in
            guard let action = HardwareMediaKeyEventPolicy.action(
                subtype: Int(event.subtype.rawValue),
                data1: event.data1
            ), PlaybackCommandCenter.shared.hasActivePlayer else { return event }

            switch action {
            case .togglePlayback:
                PlaybackCommandCenter.shared.togglePlayback()
            case .skip(let seconds):
                PlaybackCommandCenter.shared.skip(by: seconds)
            }
            return nil
        }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let window = PlaybackKeyboardRouting.window(for: event)
            let dispatched = SeeseeKeyDispatch.decide(
                isEditingText: PlaybackKeyboardRouting.isEditingText(in: window),
                bookAvailable: DigestCommandCenter.shared.bookAvailable,
                hasActivePlayer: PlaybackCommandCenter.shared.hasActivePlayer,
                keyCode: event.keyCode,
                character: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
            )

            switch dispatched {
            case .digest(let action):
                switch action {
                case .moveFocus:
                    return DigestCommandCenter.shared.perform(action) ? nil : event
                default:
                    if event.isARepeat { return nil }
                    return DigestCommandCenter.shared.perform(action) ? nil : event
                }
            case .playback(let decision):
                switch decision {
                case .passThrough:
                    return event
                case .insertLiteralSpace:
                    // 无修饰空格才会到这里。SwiftUI 字段编辑器会把普通空格交给播放按钮，
                    // 必须写入 U+0020 并消费。带修饰键的空格走 passThrough，留给系统。
                    if PlaybackKeyboardRouting.insertPlainText(" ", in: window) {
                        return nil
                    }
                    return event
                case .resignTextFocus:
                    PlaybackWindowFocusController.resign(in: event.window, reason: .escape)
                    return nil
                case .togglePlayback:
                    if !event.isARepeat {
                        PlaybackCommandCenter.shared.togglePlayback()
                    }
                    return nil
                case .toggleFullscreen:
                    if !event.isARepeat {
                        PlaybackCommandCenter.shared.toggleFullscreen()
                    }
                    return nil
                case .exitFullscreen:
                    return PlaybackCommandCenter.shared.exitFullscreen() ? nil : event
                case .skip(let seconds):
                    return PlaybackCommandCenter.shared.skip(by: seconds) ? nil : event
                case .adjustRate(let delta):
                    return PlaybackCommandCenter.shared.adjustPlaybackRate(by: delta) ? nil : event
                case .pasteURL:
                    let pasteboard = NSPasteboard.general
                    let urlType = NSPasteboard.PasteboardType("public.url")
                    guard let value = pasteboard.string(forType: .string)
                            ?? pasteboard.string(forType: urlType) else {
                        NSSound.beep()
                        return nil
                    }
                    self?.inbox.receiveClipboard(value)
                    return nil
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemMediaController.shared.stop()
        agentLink?.stop()
        agentLink = nil
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
        }
        if let mediaKeyMonitor {
            NSEvent.removeMonitor(mediaKeyMonitor)
        }
    }

    /// 本机只读查询通道：给 `seesee --mcp-stdio` 桥接进程查正在看的位置、字幕和画面。
    /// 路径被别的文件占住或过长时不启动，只记日志，不影响播放。
    private func startAgentLink() {
        let server = AgentLinkServer(
            paths: .standard(),
            provider: NowPlayingAgentProvider(),
            log: { NSLog("seesee 查询通道：%@", $0) }
        )
        if server.start() == .started {
            agentLink = server
        }
    }

    /// 与基线 WindowGroup 一致：关最后一窗后进程保留，等 reopen / 再次 open 重建。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        inbox.receive(urls)
        Self.activateFocusOrReopenMainWindow(application)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        inbox.receive(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
        Self.activateFocusOrReopenMainWindow(sender)
    }

    /// 有可见主窗口时只置前；无窗口时用捕获的 openWindow 重建，避免叠第二个。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)
        if flag || Self.focusExistingMainWindow(in: sender) {
            return false
        }
        if Self.reopenMainWindowIfNeeded() {
            return false
        }
        // openWindow 尚未挂上时退回系统：允许 WindowGroup 建恰好一个。
        return true
    }

    private static func activateFocusOrReopenMainWindow(_ application: NSApplication) {
        application.activate(ignoringOtherApps: true)
        if focusExistingMainWindow(in: application) {
            return
        }
        _ = reopenMainWindowIfNeeded()
    }

    /// 只认主窗口：排除 LocalVideoPlayer 后台浮窗等 NSPanel。
    @discardableResult
    private static func focusExistingMainWindow(in application: NSApplication) -> Bool {
        let candidates = application.windows.filter { window in
            guard window.canBecomeKey || window.canBecomeMain else { return false }
            // 浮窗播放器是 NSPanel，不应当成主窗口置前目标。
            if window is NSPanel { return false }
            return true
        }
        guard let window = candidates.first(where: \.isVisible) ?? candidates.first else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    @discardableResult
    private static func reopenMainWindowIfNeeded() -> Bool {
        guard let open = MainWindowOpener.open else { return false }
        open()
        return true
    }
}
