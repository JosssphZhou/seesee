import AppKit
import Foundation

/// 安装检查只启动隔离家目录中的旧版副本，不激活窗口。
@main
struct InstallScriptBackground {
    enum Failed: Error { case invalidArguments, wrongApplication }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 else { throw Failed.invalidArguments }
        let root = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
        let app = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
        guard root.path.hasPrefix("/private/tmp/ss-install-check-codex.") || root.path.hasPrefix("/tmp/ss-install-check-codex.") else {
            throw NSError(domain: "测试根目录不符：\(root.path)", code: 1)
        }
        guard app.path.hasPrefix(root.path + "/"), home.path.hasPrefix(root.path + "/"),
              Bundle(url: app)?.bundleIdentifier?.hasPrefix("ai.openmy.seesee.install-check.") == true else {
            throw NSError(domain: "测试副本不符：\(app.path)，家目录\(home.path)，ID\(Bundle(url: app)?.bundleIdentifier ?? "nil")", code: 2)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["CFFIXED_USER_HOME": home.path]
        let running: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { application, error in
                if let error { continuation.resume(throwing: error) }
                else if let application { continuation.resume(returning: application) }
                else { continuation.resume(throwing: Failed.wrongApplication) }
            }
        }
        guard running.bundleURL?.resolvingSymlinksInPath() == app else {
            throw NSError(domain: "启动返回路径不符：\(running.bundleURL?.path ?? "nil")，请求\(app.path)，PID\(running.processIdentifier)", code: 3)
        }
        print(running.processIdentifier)
    }
}
