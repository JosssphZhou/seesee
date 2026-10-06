import Foundation

/// 下载中改的名，下载完成时不能被视频网站的标题冲掉。
/// 从真实的 `QueueStore()` 启动：队列从临时家目录的 queue.json 读出，启动时自动开始下载；
/// 假 yt-dlp 先报一次元数据，等检查程序改完名再下完、再报一次元数据。
/// 只用改动之前就有的接口（`rename`、`items`、`title`），旧代码上也能编译运行，并在最后一条断言失败。
/// 只能经 scripts/test_title_fields.sh 运行：它造一个临时应用、临时家目录和假的 yt-dlp。

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
    if !condition() { throw CheckFailure(description: message()) }
}

@main
@MainActor
struct TitleRenameRegressionCheck {
    /// 假 yt-dlp 报的标题。用中文，免得被自动翻译成别的字，检查只看改名有没有被冲掉。
    static let metadataTitle = "视频网站给的原标题"
    static let renamed = "我在下载中改的名字"

    static func main() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["TITLE_CHECK_ROOT"] else {
            throw CheckFailure(description: "请经 scripts/test_title_fields.sh 运行")
        }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let queueFolder = try refuseOutsideScratch(root: root)

        let seeded = WatchItem(
            id: UUID(),
            urlString: "https://example.com/videos/title-rename-regression",
            title: "example.com",
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
        try FileManager.default.createDirectory(at: queueFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([seeded]).write(to: queueFolder.appendingPathComponent("queue.json"))

        let store = QueueStore()
        let started = Date()
        var log: [String] = []
        func note(_ text: String) {
            log.append(String(format: "  %5.2f 秒  ", Date().timeIntervalSince(started)) + text)
        }
        func current() -> WatchItem? { store.items.first { $0.id == seeded.id } }

        // 1. 等下载开始、第一次元数据到达。
        try await waitUntil("下载开始并收到元数据", started: started, log: { log }) {
            guard let item = current() else { return false }
            try failIfEnvironmentBlocks(item, seconds: Date().timeIntervalSince(started))
            return item.state == .downloading && item.title == metadataTitle
        }
        note("下载中，标题是「\(current()?.title ?? "")」")

        // 2. 下载中改名。
        store.rename(seeded.id, to: renamed)
        note("改名后标题是「\(current()?.title ?? "")」")
        try check(current()?.title == renamed, "改名没有生效：\(current()?.title ?? "条目不见了")")

        // 3. 放行假 yt-dlp：下完，再报一次元数据（真实 yt-dlp 下完时的 WL_DONE 也带标题）。
        FileManager.default.createFile(atPath: root.appendingPathComponent("go").path, contents: nil)
        try await waitUntil("下载完成", started: started, log: { log }) {
            guard let item = current() else { return false }
            return item.state == .ready || item.state == .failed
        }
        note("下载结束，状态 \(current()?.state.rawValue ?? "")，标题是「\(current()?.title ?? "")」")
        let detail = "\n经过：\n" + log.joined(separator: "\n")
        try check(current()?.state == .ready, "下载没有完成。\(detail)")
        try check(
            current()?.title == renamed,
            "下载完成后改的名被冲掉了：现在是「\(current()?.title ?? "")」，应该还是「\(renamed)」。\(detail)"
        )

        // 4. 落盘的也是改的名。
        store.flushPendingSaves()
        let data = try Data(contentsOf: queueFolder.appendingPathComponent("queue.json"))
        let saved = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first
        try check(
            saved?["title"] as? String == renamed,
            "queue.json 里存的标题不是改的名：\(saved?["title"] ?? "没有")。\(detail)"
        )
        print("title_rename_regression_check=passed（真实 QueueStore，假工具：下载中改的名，下完以后不被元数据覆盖，落盘的也是改的名）")
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
