import Foundation

enum MediaFolderPreference {
    static let key = "MediaFolderPath"

    static func resolve(defaults: UserDefaults) -> URL? {
        guard let path = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func save(_ url: URL, defaults: UserDefaults) {
        defaults.set(url.standardizedFileURL.path, forKey: key)
    }
}
