import Foundation

enum MediaFolderLaunchArguments {
    static let flag = "--move-media-folder"

    static func moveDestination(from arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        let raw = arguments[index + 1]
        guard !raw.isEmpty, !raw.hasPrefix("-") else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }
}
