import Foundation

enum MediaFolderAvailability {
    static let defaultVolumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)

    static func liveMountedVolumes() -> [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: []
        ) ?? []
    }

    /// 路径落在卷根（默认 `/Volumes/<卷名>/…`）且该卷不在已挂载列表里，即为未连接。
    /// 不能只看目录是否存在：未挂载时 `createDirectory` 可能在 `/Volumes` 下造出同名空目录。
    static func isDisconnected(
        _ url: URL,
        mountedVolumes: [URL],
        volumesRoot: URL = defaultVolumesRoot
    ) -> Bool {
        let path = url.standardizedFileURL.path
        let root = volumesRoot.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return false }
        let remainder = path == root ? "" : String(path.dropFirst(root.count + 1))
        let volumeName = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        guard !volumeName.isEmpty else { return false }
        return !isMounted(volumeName, volumes: mountedVolumes, volumesRoot: volumesRoot)
    }

    private static func isMounted(_ name: String, volumes: [URL], volumesRoot: URL) -> Bool {
        let expected = volumesRoot.appendingPathComponent(name, isDirectory: true).standardizedFileURL.path
        return volumes.contains { volume in
            let volumePath = volume.standardizedFileURL.path
            return volumePath == expected
                || volume.standardizedFileURL.lastPathComponent == name
        }
    }
}
