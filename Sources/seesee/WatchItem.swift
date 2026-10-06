import Foundation

enum DownloadState: String, Codable {
    case queued
    case downloading
    case ready
    case failed
}

struct VideoChapter: Codable, Hashable, Identifiable {
    var title: String
    var startTime: Double
    var endTime: Double?

    var id: String { "\(startTime)-\(title)" }
}

/// A playable source may be a finished local movie or the combined remote
/// stream exposed while the high-quality offline copy is still downloading.
struct VideoPlaybackSource: Equatable, Hashable {
    let videoURL: URL

    init(videoURL: URL) {
        self.videoURL = videoURL
    }
}

struct WatchItem: Identifiable, Codable, Hashable {
    let id: UUID
    var urlString: String
    var title: String
    var author: String
    var duration: Double?
    var addedAt: Date
    var watchedAt: Date?
    var state: DownloadState
    var progress: Double
    var progressLabel: String
    var localFilePath: String?
    var errorMessage: String?
    var playbackPosition: Double?
    var chapters: [VideoChapter]?
    var thumbnailFilePath: String?
    var subtitleFilePath: String?

    var isWatched: Bool { watchedAt != nil }

    var availableChapters: [VideoChapter] { chapters ?? [] }

    /// 详情侧栏是否有可展示内容：章节列表或本地字幕文件（歌词轴）。
    var hasSidePaneContent: Bool {
        !availableChapters.isEmpty || subtitleFileURL != nil
    }

    var resumablePosition: Double {
        let position = max(0, playbackPosition ?? 0)
        guard position >= 3 else { return 0 }
        if let duration, duration > 0, position >= duration - 10 { return 0 }
        return position
    }

    var sourceName: String {
        guard var host = URL(string: urlString)?.host?.lowercased() else { return "视频" }
        if host.contains("youtu") { return "YouTube" }
        if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter") { return "X" }
        if host.contains("bilibili") || host == "b23.tv" || host.hasSuffix(".b23.tv") { return "哔哩哔哩" }
        if host.contains("xiaohongshu") || host.contains("xhslink") { return "小红书" }
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        guard let first = label.first else { return "视频" }
        return String(first).uppercased() + label.dropFirst()
    }

    var localFileURL: URL? {
        guard let localFilePath else { return nil }
        let url = URL(fileURLWithPath: localFilePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var thumbnailFileURL: URL? {
        guard let thumbnailFilePath, !thumbnailFilePath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: thumbnailFilePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var subtitleFileURL: URL? {
        guard let subtitleFilePath, !subtitleFilePath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: subtitleFilePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum QueueOrderPolicy {
    static let currentVersion = 1
    static let versionDefaultsKey = "queueOrderVersion"

    static func newestFirst(_ items: [WatchItem]) -> [WatchItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.addedAt == rhs.element.addedAt {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.addedAt > rhs.element.addedAt
            }
            .map(\.element)
    }
}
