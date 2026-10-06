import AppKit
import Foundation
import CoreGraphics

/// 只管理调用方给出的测试副本和PID，不激活应用、不操作鼠标键盘。
@main
struct SeeseeBackgroundCheck {
    enum Failed: Error { case invalidArguments, permissionMissing, wrongProcess, noWindows, unsupported }
    @MainActor static func main() async throws {
        let helperApplication = NSApplication.shared
        helperApplication.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { throw Failed.invalidArguments }
        if command == "preflight" {
            guard CGPreflightScreenCaptureAccess() else { throw Failed.permissionMissing }
            print("screen_capture_permission=available"); return
        }
        guard args.count >= 2 else { throw Failed.invalidArguments }
        let appURL = URL(fileURLWithPath: args[1]).standardizedFileURL
        guard let identifier = Bundle(url: appURL)?.bundleIdentifier,
              identifier.hasPrefix("ai.openmy.seesee.correct-original") else { throw Failed.invalidArguments }
        if command == "launch" {
            guard args.count == 3 else { throw Failed.invalidArguments }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.createsNewApplicationInstance = true
            configuration.environment = ["CFFIXED_USER_HOME": args[2]]
            let application: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let app { continuation.resume(returning: app) }
                    else { continuation.resume(throwing: Failed.wrongProcess) }
                }
            }
            print(application.processIdentifier); return
        }
        guard args.count >= 3, let pid = Int32(args[2]),
              let application = NSRunningApplication(processIdentifier: pid),
              application.bundleURL?.standardizedFileURL == appURL else { throw Failed.wrongProcess }
        if command == "stop" {
            guard application.terminate() else { throw Failed.wrongProcess }
            for _ in 0..<100 {
                if application.isTerminated { print("owned_pid_exited=\(pid)"); return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw Failed.wrongProcess
        }
        guard command == "screenshot", args.count == 4 else { throw Failed.invalidArguments }
        guard CGPreflightScreenCaptureAccess() else { throw Failed.permissionMissing }
        let content = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = content.filter {
            guard ($0[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let bounds = $0[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? Double ?? 0) > 100,
                  (bounds["Height"] as? Double ?? 0) > 100 else { return false }
            return ($0[kCGWindowLayer as String] as? Int) == 0 || ($0[kCGWindowIsOnscreen as String] as? Bool) == true
        }
        guard !windows.isEmpty else { throw Failed.noWindows }
        let target = URL(fileURLWithPath: args[3])
        for window in windows {
            guard let id = window[kCGWindowNumber as String] as? Int else { throw Failed.noWindows }
            let path = target.deletingPathExtension().appendingPathExtension("window-\(id).png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(id), path.path]
            try capture.run(); capture.waitUntilExit()
            guard capture.terminationStatus == 0, NSImage(contentsOf: path) != nil else { throw Failed.noWindows }
            print(path.path)
        }
    }
}
