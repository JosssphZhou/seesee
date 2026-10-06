import AppKit

enum DigestSettingsOpener {
    /// 打开 SwiftUI Settings 场景的窗口（macOS 13 起菜单项叫「设置…」）。
    @MainActor
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}
