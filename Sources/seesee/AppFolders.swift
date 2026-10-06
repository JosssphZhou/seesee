import Foundation

/// 应用数据目录和默认片库共用的文件夹名：`~/Library/Application Support/seesee`、`~/Movies/seesee`。
enum AppFolders {
    static let applicationName = "seesee"

    static func applicationSupport(root applicationSupportRoot: URL) -> URL {
        applicationSupportRoot.appendingPathComponent(applicationName, isDirectory: true)
    }

    static func defaultMediaFolder(moviesRoot: URL) -> URL {
        moviesRoot.appendingPathComponent(applicationName, isDirectory: true)
    }
}

/// 片库换位置后，把 queue.json 里指向旧片库的绝对路径改到新片库下；旧片库以外的路径原样保留。
struct MediaPathRemap {
    let mediaFolder: URL
    let movedFromMediaFolder: URL

    func remappedMediaPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let legacyPrefix = movedFromMediaFolder.standardizedFileURL.path + "/"
        guard path.hasPrefix(legacyPrefix) else { return path }
        let relativePath = String(path.dropFirst(legacyPrefix.count))
        return mediaFolder.appendingPathComponent(relativePath).path
    }
}
