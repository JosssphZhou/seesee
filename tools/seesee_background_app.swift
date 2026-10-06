import AppKit
import CoreGraphics
import Foundation

/// 隔离副本的后台启动、按已登记 PID 回读及退出；没有键鼠操作。
@main
struct BackgroundTestApp {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let command = args[1]
        let path = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
        let info = NSDictionary(contentsOf: path.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == "ai.openmy.seesee.mcp",
              info?["CFBundleExecutable"] as? String == "seesee-mcp" else {
            throw NSError(domain: "隔离副本身份不符", code: 1)
        }
        if command == "launch" || command == "preflight" {
            guard NSWorkspace.shared.runningApplications.allSatisfy({ $0.bundleIdentifier != "ai.openmy.seesee.mcp" }) else {
                throw NSError(domain: "已有另一份隔离副本在运行，本次不启动", code: 2)
            }
            if command == "preflight" { print("没有其他隔离副本运行"); return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.createsNewApplicationInstance = true
            configuration.environment = ["CFFIXED_USER_HOME": args[3]]
            let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: path, configuration: configuration) { app, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let app { continuation.resume(returning: app) }
                    else { continuation.resume(throwing: NSError(domain: "启动没有返回进程", code: 3)) }
                }
            }
            guard app.bundleURL?.resolvingSymlinksInPath() == path else {
                throw NSError(domain: "系统没有启动指定副本", code: 4)
            }
            print(app.processIdentifier)
            return
        }
        guard let pid = Int32(args[3]), let app = NSRunningApplication(processIdentifier: pid),
              app.bundleURL?.resolvingSymlinksInPath() == path else {
            throw NSError(domain: "已登记 PID 不属于本轮副本", code: 5)
        }
        if command == "stop" { app.terminate(); return }
        guard command == "screenshot", CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: "没有已有截图权限，未请求新权限", code: 6)
        }
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        guard let window = owned.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let id = window[kCGWindowNumber as String] as? Int else {
            throw NSError(domain: "找不到本轮副本窗口", code: 7)
        }
        let output = URL(fileURLWithPath: args[4])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(id), output.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0, NSImage(contentsOf: output) != nil else {
            throw NSError(domain: "截图缺失或无法解码", code: 8)
        }
        print("截图 PID=\(pid) window=\(id) file=\(output.path)")
        // 后台播放会把视频移到自己的悬浮窗（非0层）；主窗黑色不能当作视频黑屏。
        for panel in owned where (panel[kCGWindowLayer as String] as? Int) != 0 && panel[kCGWindowIsOnscreen as String] as? Bool == true {
            guard let panelID = panel[kCGWindowNumber as String] as? Int,
                  let bounds = panel[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? Double ?? 0) >= 150, (bounds["Height"] as? Double ?? 0) >= 100 else { continue }
            let panelOutput = output.deletingPathExtension().appendingPathExtension("window-\(panelID).png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(panelID), panelOutput.path]
            try capture.run(); capture.waitUntilExit()
            guard capture.terminationStatus == 0, NSImage(contentsOf: panelOutput) != nil else {
                throw NSError(domain: "本轮悬浮窗截图无法解码", code: 9)
            }
            print("截图 PID=\(pid) layer=\(panel[kCGWindowLayer as String] ?? 0) window=\(panelID) file=\(panelOutput.path)")
        }
    }
}
