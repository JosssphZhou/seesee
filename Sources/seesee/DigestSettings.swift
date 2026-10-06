import AppKit
import Foundation

enum DigestSettingsCopy {
    static let windowTitle = "设置"
    static let gearTitle = "设置"
    static let dataSectionTitle = "数据位置"
    static let mediaLabel = "影片"
    static let revealTitle = "打开"

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
