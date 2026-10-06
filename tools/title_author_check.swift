import Foundation

/// 作者中文标题：YouTube 视频开始下载时后台问一次作者有没有中文标题，原标题到了以后用它做主标题，
/// 来源记作 author，本机翻译的结果不能把它换回去。从真实的 `QueueStore()` 启动，yt-dlp 是假的：
/// 下载时报英文原标题，平铺列表时报作者的中文标题。
/// 只能经 scripts/test_title_fields.sh 运行：它造一个临时应用、临时家目录和假的 yt-dlp。

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
    if !condition() { throw CheckFailure(description: message()) }
}

@main
@MainActor
struct TitleAuthorCheck {
    static let original = "$456,000 Squid Game In Real Life!"
    static let localized = "现实版鱿鱼游戏，坚持到最后赢得456,000美元！"

    static func main() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["TITLE_CHECK_ROOT"] else {
            throw CheckFailure(description: "请经 scripts/test_title_fields.sh 运行")
        }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let queueFolder = try refuseOutsideScratch(root: root)

        var seeded = WatchItem(
            id: UUID(),
            urlString: "https://www.youtube.com/watch?v=0e3GPea1Tyg",
            title: "youtube.com",
            author: "",
            duration: nil,
            addedAt: Date(),
            watchedAt: nil,
            state: .queued,
            progress: 0,
            progressLabel: "排队中",
            localFilePath: nil,
            errorMessage: nil,
            playbackPosition: nil,
            chapters: nil,
            thumbnailFilePath: nil,
            subtitleFilePath: nil
        )
        seeded.originalTitle = "youtube.com"
        try FileManager.default.createDirectory(at: queueFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([seeded]).write(to: queueFolder.appendingPathComponent("queue.json"))

        let store = QueueStore()
        let started = Date()
        var log: [String] = []
        var lastSeen = ""
        func current() -> WatchItem? { store.items.first { $0.id == seeded.id } }

        try await waitUntil("作者中文标题成为主标题", started: started, log: { log }) {
            guard let item = current() else { return false }
            let seen = "\(item.state.rawValue) 原「\(item.originalTitle ?? "")」译「\(item.translatedTitle ?? "")」(\(item.translatedTitleSource ?? "无"))"
            if seen != lastSeen {
                lastSeen = seen
                log.append(String(format: "  %5.2f 秒  ", Date().timeIntervalSince(started)) + seen)
            }
            return item.state == .ready && item.titleTranslationSource == .author
        }
        // 本机翻译可能晚一点回来；再等一秒，确认它没有把作者标题换掉。
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let detail = "\n经过：\n" + log.joined(separator: "\n")
        let item = current()
        try check(item?.originalTitle == original, "原标题不对：\(item?.originalTitle ?? "")。\(detail)")
        try check(item?.translatedTitle == localized && item?.titleTranslationSource == .author,
                  "主标题应是作者的中文标题：\(item?.translatedTitle ?? "") \(item?.translatedTitleSource ?? "")。\(detail)")
        try check(item?.title == localized && item?.titleDisplay.secondary == original,
                  "显示应是中文主标题、下面一行原标题：\(String(describing: item?.titleDisplay))。\(detail)")
        store.flushPendingSaves()
        let data = try Data(contentsOf: queueFolder.appendingPathComponent("queue.json"))
        let saved = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first
        try check(saved?["translatedTitleSource"] as? String == "author" && saved?["originalTitle"] as? String == original,
                  "queue.json 里没存下作者标题：\(saved ?? [:])")
        print("title_author_check=passed（真实 QueueStore，假 yt-dlp：作者中文标题做主标题，来源 author，原标题在下面一行）" + detail)
    }

    private static func waitUntil(
        _ what: String,
        started: Date,
        timeout: Double = 40,
        log: () -> [String],
        _ condition: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
            if Date() >= deadline {
                throw CheckFailure(description: "\(Int(timeout)) 秒内没有等到「\(what)」。\n经过：\n" + log().joined(separator: "\n"))
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 队列等网络或低电量模式暂停时测不到；说清楚是环境原因。
    private static func failIfEnvironmentBlocks(_ item: WatchItem, seconds: Double) throws {
        guard seconds > 10 else { return }
        try check(
            item.progressLabel != "等待网络连接",
            "系统一直报告没有网络连接，队列不开始下载。这项检查本身不联网，但要在系统报告在线时运行。"
        )
        try check(
            item.progressLabel != "低电量模式已暂停",
            "低电量模式开着，队列暂停了下载。关掉低电量模式再运行这项检查。"
        )
    }

    /// 开工前核对：工具、家目录、队列文件都在临时目录里，偏好设置域是测试专用的，片库没有被指到别处。
    private static func refuseOutsideScratch(root: URL) throws -> URL {
        let resources = Bundle.main.resourceURL?.resolvingSymlinksInPath().path ?? ""
        try check(resources.hasPrefix(root.path + "/"), "拒绝使用临时应用之外的工具")
        try check(
            Bundle.main.bundleIdentifier == "ai.openmy.seesee.tests.title-fields",
            "拒绝在 seesee 的偏好设置域里运行"
        )
        let homePath = NSHomeDirectory()
        let home = URL(fileURLWithPath: homePath).resolvingSymlinksInPath().path
        try check(home.hasPrefix(root.path + "/"), "拒绝在真实的家目录下运行")
        try check(
            FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix(homePath),
            "片库会落在临时家目录之外"
        )
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try check(supportRoot.path.hasPrefix(homePath + "/"), "队列文件会落在临时家目录之外")
        try check(
            MediaFolderPreference.resolve(defaults: .standard) == nil,
            "测试用的偏好设置里记着片库位置，视频会写到临时目录之外"
        )
        return supportRoot.appendingPathComponent(AppFolders.applicationName, isDirectory: true)
    }
}
