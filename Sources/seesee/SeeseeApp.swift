import AppKit
import SwiftUI

/// 在主窗口存活时捕获 `openWindow`，关窗后由 AppDelegate 重建主窗口（进程不退出）。
@MainActor
enum MainWindowOpener {
    static let sceneID = "main"
    static var open: (() -> Void)?
}

/// 把 SwiftUI `openWindow` 挂到 AppDelegate 可调用的入口上。
private struct MainWindowOpenBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                MainWindowOpener.open = {
                    openWindow(id: MainWindowOpener.sceneID)
                }
            }
    }
}

/// 入口在 SeeseeEntry：先分流 `--mcp-stdio`，其余情况才启动应用。
struct SeeseeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = QueueStore()
    @AppStorage(LibraryViewMode.defaultsKey) private var viewMode: LibraryViewMode = .list

    var body: some Scene {
        // 保留 WindowGroup：关最后一窗后进程仍存活（基线行为）。
        // matching 为空：外部 URL 不由 scene 新开窗；URL 入队走 AppDelegate。
        // 无窗重建走 MainWindowOpener（捕获的 openWindow），避免叠窗。
        WindowGroup(id: MainWindowOpener.sceneID) {
            ContentView()
                .environmentObject(store)
                .environmentObject(appDelegate.inbox)
                .tint(OpenMyChrome.ink)
                .background(MainWindowOpenBridge())
                .onAppear { appDelegate.attachQueueStore(store) }
                // 本机翻译标题要弹语言下载提示、或系统只能从视图拿翻译会话时，挂在主窗口上。
                .modifier(TitleTranslationHost())
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.stopLocalTranscriptionQueue()
                    store.flushPendingSaves()
                }
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .sidebar) {
                // 「显示」菜单：⌘1 列表视图、⌘2 看板视图，当前用的那种打勾。
                ForEach(LibraryViewMode.allCases) { mode in
                    Toggle(mode.title, isOn: Binding(
                        get: { viewMode == mode },
                        set: { if $0 { viewMode = mode } }
                    ))
                    .keyboardShortcut(KeyEquivalent(mode.shortcutKey), modifiers: .command)
                }
                Divider()
                Button("显示或隐藏左侧栏") {
                    NotificationCenter.default.post(name: .seeseeSidebarToggle, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(viewMode == .board)
            }
            CommandGroup(after: .appInfo) {
                Button("打开下载文件夹") { store.revealMediaFolder() }
                Button("检查订阅更新") { store.channelWatch.pollAll() }
            }
        }

        // 应用菜单「设置…」（⌘,）与标题栏齿轮：片库位置在这里查看和更改。
        Settings {
            DigestSettingsLiveView(store: store)
                .tint(OpenMyChrome.ink)
        }
        .windowResizability(.contentSize)
    }
}
