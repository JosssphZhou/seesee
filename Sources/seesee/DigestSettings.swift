import AppKit
import Foundation

enum DigestSettingsCopy {
    static let windowTitle = "设置"
    static let gearTitle = "设置"
    static let generalSectionTitle = "通用"
    static let playbackSectionTitle = "播放"
    static let transcriptionSectionTitle = "转写"
    static let dataSectionTitle = "存放位置"
    static let agentSectionTitle = "Agent 接入"
    static let archivedColumnLabel = "显示「已归档」列"
    static let sponsorSkipLabel = "自动跳过赞助段"
    static let transcriptionModelLabel = "转写模型"
    static let transcriptionNotInstalled = "未安装"
    static let transcriptionDownload = "下载"
    static let transcriptionAvailable = "可用"
    static let transcriptionFailed = "下载失败"
    static let transcriptionRetry = "重试"
    static let transcriptionUnsupported = "需要 macOS 26 或更新版本"
    static let mediaLabel = "影片"
    static let revealTitle = "打开"
    static let claudeCodeLabel = "Claude Code"
    static let codexLabel = "Codex"
    static let copyCommand = "拷贝命令"
    static let copyConfig = "拷贝配置"
    static let copied = "已拷贝"

    /// 家目录缩写成 ~，路径给人看。
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// 设置页「Agent 接入」两个按钮拷贝的内容，和 README 一致，应用路径按实际所在位置生成。
enum AgentSetupSnippet {
    /// 和 `SeeseeMCPBridge.stdioFlag` 同一个参数；这里不引用它，设置页的检查不用连带编译 MCP 桥接。
    static let stdioFlag = "--mcp-stdio"

    /// 应用包里的 seesee 可执行文件。可执行文件名取实际的名字，正式包里就是 seesee。
    static func executablePath(
        bundleURL: URL = Bundle.main.bundleURL,
        executableName: String = Bundle.main.executableURL?.lastPathComponent ?? "seesee"
    ) -> String {
        bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
            .path
    }

    static func claudeCode(executablePath: String) -> String {
        "claude mcp add --scope user seesee -- \(shellQuoted(executablePath)) \(stdioFlag)"
    }

    static func codex(executablePath: String) -> String {
        """
        [mcp_servers.seesee]
        command = "\(tomlEscaped(executablePath))"
        args = ["\(stdioFlag)"]
        """
    }

    /// 只含常见安全字符时原样输出，和 README 一字不差；有空格等字符时整段加单引号。
    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+@%:,=")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func tomlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// 设置窗口的状态：片库位置、未连接、搬移进度和旧位置，由设置窗从 QueueStore 同步进来。
@MainActor
final class DigestSettingsModel: ObservableObject {
    @Published var mediaFolder: URL?
    @Published var isMediaFolderDisconnected = false
    @Published var mediaFolderMoveProgress: MediaLibraryMoveProgress?
    @Published var mediaFolderMoveFailure: String?
    @Published var previousMediaFolder: URL?
    var onChangeMediaFolder: (() -> Void)?

    init(mediaFolder: URL? = nil, isMediaFolderDisconnected: Bool = false) {
        self.mediaFolder = mediaFolder
        self.isMediaFolderDisconnected = isMediaFolderDisconnected
    }

    var mediaPathText: String { mediaFolder.map(DigestSettingsCopy.displayPath) ?? "" }

    func revealMediaFolder() {
        guard let mediaFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([mediaFolder])
    }

    var previousMediaPathText: String { previousMediaFolder.map(DigestSettingsCopy.displayPath) ?? "" }

    func revealPreviousMediaFolder() {
        guard let previousMediaFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([previousMediaFolder])
    }
}
