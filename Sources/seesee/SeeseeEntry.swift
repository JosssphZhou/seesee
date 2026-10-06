import Foundation

/// 进程入口：带 `--mcp-stdio` 时只做 MCP 桥接后退出，这条路径不碰 AppKit、SwiftUI 和队列；
/// 否则启动应用。分流必须在任何 AppKit 调用之前完成，否则会出现 Dock 图标。
@main
enum SeeseeEntry {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().contains(SeeseeMCPBridge.stdioFlag) {
            exit(SeeseeMCPBridge.runStdio())
        }
        SeeseeApp.main()
    }
}
