import AppKit
import SwiftUI

/// 设置页离屏证明：存放位置四种提示、转写模型五种状态各渲染一张，深浅各一套；
/// 同时核对 Agent 接入拷贝的两段文字。图片默认写到 /tmp，`SETTINGS_PROOF_DIR` 可改目录。
@main
struct MediaFolderSettingsProof {
    static let outputDirectory = ProcessInfo.processInfo.environment["SETTINGS_PROOF_DIR"] ?? "/tmp"

    @MainActor
    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        checkAgentSnippets()

        let media = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/seesee")
        let external = URL(fileURLWithPath: "/Volumes/外置硬盘/seesee", isDirectory: true)

        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let connectedHeight = render(
                model: DigestSettingsModel(mediaFolder: media),
                transcription: .available,
                appearance: appearance,
                name: "settings-connected-\(suffix)"
            )

            let disconnected = DigestSettingsModel(mediaFolder: external, isMediaFolderDisconnected: true)
            let disconnectedHeight = render(model: disconnected, appearance: appearance, name: "settings-disconnected-\(suffix)")
            precondition(disconnectedHeight > connectedHeight, "未连接应多出提示一行")

            let switched = DigestSettingsModel(mediaFolder: external)
            switched.previousMediaFolder = media
            precondition(switched.previousMediaPathText == DigestSettingsCopy.displayPath(media))
            let switchedHeight = render(model: switched, appearance: appearance, name: "settings-switched-\(suffix)")
            precondition(switchedHeight > connectedHeight, "切换后应多出旧位置一行")

            let moving = DigestSettingsModel(mediaFolder: external)
            moving.mediaFolderMoveProgress = MediaLibraryMoveProgress(completed: 12, total: 40)
            let movingHeight = render(model: moving, appearance: appearance, name: "settings-moving-\(suffix)")
            precondition(movingHeight > connectedHeight, "搬移中应多出进度一行")

            let failed = DigestSettingsModel(mediaFolder: media)
            failed.mediaFolderMoveFailure = MediaFolderCopy.failure(MediaFolderCopy.destinationDisconnected)
            let failedHeight = render(model: failed, appearance: appearance, name: "settings-move-failed-\(suffix)")
            precondition(failedHeight > connectedHeight, "搬移失败应多出失败一行")

            // 五组七行，深浅两套高度一致，整页不超过 600。
            precondition(connectedHeight <= 600, "设置页高度 \(connectedHeight) 超出预期")

            let states: [(TranscriptionModelState, String)] = [
                (.notInstalled, "not-installed"),
                (.downloading(fraction: 0.38), "downloading"),
                (.available, "available"),
                (.failed, "failed"),
                (.unsupportedSystem, "unsupported"),
            ]
            for (state, name) in states {
                let height = render(
                    model: DigestSettingsModel(mediaFolder: media),
                    transcription: state,
                    appearance: appearance,
                    name: "settings-transcription-\(name)-\(suffix)"
                )
                precondition(abs(height - connectedHeight) < 0.5, "转写模型 \(name) 不应改变整页高度")
            }
        }
        print("media_folder_settings_proof=passed dir=\(outputDirectory)")
    }

    /// Agent 接入：常见路径和 README 一字不差；路径带空格或引号时命令仍能贴进终端，配置仍是合法 TOML。
    @MainActor
    private static func checkAgentSnippets() {
        let installed = AgentSetupSnippet.executablePath(
            bundleURL: URL(fileURLWithPath: "/Applications/seesee.app", isDirectory: true),
            executableName: "seesee"
        )
        precondition(installed == "/Applications/seesee.app/Contents/MacOS/seesee")
        precondition(
            AgentSetupSnippet.claudeCode(executablePath: installed)
                == "claude mcp add --scope user seesee -- /Applications/seesee.app/Contents/MacOS/seesee --mcp-stdio"
        )
        precondition(
            AgentSetupSnippet.codex(executablePath: installed)
                == "[mcp_servers.seesee]\ncommand = \"/Applications/seesee.app/Contents/MacOS/seesee\"\nargs = [\"--mcp-stdio\"]"
        )

        let spaced = "/Applications/My Apps/it's seesee.app/Contents/MacOS/seesee"
        let command = AgentSetupSnippet.claudeCode(executablePath: spaced)
        precondition(command.hasSuffix(" --mcp-stdio"))
        let quotedPart = String(command.dropFirst("claude mcp add --scope user seesee -- ".count).dropLast(" --mcp-stdio".count))
        let echoed = runShell("printf %s \(quotedPart)")
        precondition(echoed == spaced, "带空格和单引号的路径经 shell 还原为 \(echoed)")
        precondition(
            AgentSetupSnippet.codex(executablePath: "/x/\"q\\/seesee").contains(#"command = "/x/\"q\\/seesee""#)
        )
        print("agent_setup_snippet=passed")
    }

    private static func runShell(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try! process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @MainActor
    @discardableResult
    private static func render(
        model: DigestSettingsModel,
        transcription: TranscriptionModelState = .available,
        appearance: NSAppearance.Name,
        name: String
    ) -> CGFloat {
        let status = TranscriptionModelStatus(forcedState: transcription)
        let hosting = NSHostingView(rootView: DigestSettingsView(model: model, transcription: status))
        hosting.appearance = NSAppearance(named: appearance)
        let fitting = hosting.fittingSize
        let width = DigestSettingsView.width
        let height = max(fitting.height, 200)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = OpenMyChrome.nsCanvas
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let scale: CGFloat = 2
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fatalError("media_folder_settings_proof: 无法建位图") }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        let path = "\(outputDirectory)/\(name).png"
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("media_folder_settings_proof: 无法编码 \(path)")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fatalError("media_folder_settings_proof: 写 \(path) 失败 \(error)")
        }
        print("media_folder_settings_proof \(name) size=\(Int(width))x\(Int(fitting.height)) png=\(path)")
        window.close()
        // 比较的是内容高度：按画布下限比较会看不出多出的一行。
        return fitting.height
    }
}
