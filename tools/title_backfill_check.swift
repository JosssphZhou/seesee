import Foundation
import Translation

/// 旧条目补翻：启动时，还没看的旧条目用本机翻译补一个中文主标题；已看的不翻，中文标题不翻，不去问作者标题。
/// 从真实的 `QueueStore()` 启动，队列是旧格式（没有原标题等新字段）。只用改动之前就有的接口
/// （`items`、`title`、`isWatched`），在没有补翻的代码上也能编译运行，并在第一条断言失败。
/// 要这台机器装了英文到简体中文的翻译语言包；没装时说明原因后跳过，不算通过也不算失败。
/// 只能经 scripts/test_title_fields.sh 运行：它造一个临时应用、临时家目录和假的 yt-dlp。

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
    if !condition() { throw CheckFailure(description: message()) }
}

@main
@MainActor
struct TitleBackfillCheck {
    static let unwatchedTitle = "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film"
    static let watchedTitle = "Sprite Fright - Blender Open Movie"
    static let chineseTitle = "李子柒为什么消失得那么彻底？"

    static func main() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["TITLE_CHECK_ROOT"] else {
            throw CheckFailure(description: "请经 scripts/test_title_fields.sh 运行")
        }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let queueFolder = try refuseOutsideScratch(root: root)
        if #available(macOS 15.0, *) {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: "en"),
                to: Locale.Language(identifier: "zh-Hans")
            )
            guard status == .installed else {
                print("title_backfill_check=skipped（这台机器没装英文到简体中文的翻译语言包，本机翻译翻不了；在系统设置的翻译语言里装上后再跑）")
                return
            }
        } else {
            print("title_backfill_check=skipped（macOS 15 以前没有本机翻译）")
            return
        }

        // 旧格式：直接写 JSON，不带 originalTitle 等新字段。
        let unwatchedID = UUID(), watchedID = UUID(), chineseID = UUID()
        func legacy(_ id: UUID, _ title: String, watched: Bool, index: Int) -> [String: Any] {
            var object: [String: Any] = [
                "id": id.uuidString,
                "urlString": "https://www.youtube.com/watch?v=backfill000\(index)",
                "title": title,
                "author": "Blender",
                "addedAt": "2026-10-01T08:00:0\(index)Z",
                "state": "ready",
                "progress": 1,
                "progressLabel": "已下载",
                // 章节、封面、字幕都记成「找过了」，启动时不去补取元数据。补取会用假 yt-dlp 的空结果改掉原标题。
                "chapters": [Any](),
                "thumbnailFilePath": "",
                "subtitleFilePath": ""
            ]
            if watched { object["watchedAt"] = "2026-10-02T08:00:00Z" }
            return object
        }
        let legacyQueue = [
            legacy(unwatchedID, unwatchedTitle, watched: false, index: 1),
            legacy(watchedID, watchedTitle, watched: true, index: 2),
            legacy(chineseID, chineseTitle, watched: false, index: 3)
        ]
        try FileManager.default.createDirectory(at: queueFolder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacyQueue)
            .write(to: queueFolder.appendingPathComponent("queue.json"))

        let store = QueueStore()
        let started = Date()
        func title(_ id: UUID) -> String { store.items.first { $0.id == id }?.title ?? "条目不见了" }
        func hasChinese(_ text: String) -> Bool {
            text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }

        // 1. 没看的英文旧条目补上中文主标题。
        do {
            try await waitUntil("没看的旧条目补上中文主标题", started: started, timeout: 20, log: { [] }) {
                hasChinese(title(unwatchedID))
            }
        } catch {
            let state = store.items.first { $0.id == unwatchedID }.map { "状态 \($0.state.rawValue)，\($0.progressLabel)" } ?? ""
            throw CheckFailure(description: "启动 20 秒后，没看的旧条目还是「\(title(unwatchedID))」（\(state)），没有补翻成中文")
        }
        // 再等一秒，让另外两条要是会被翻也有时间翻完。
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try check(title(watchedID) == watchedTitle, "已看的旧条目不该补翻，现在是「\(title(watchedID))」")
        try check(title(chineseID) == chineseTitle, "中文标题不该翻，现在是「\(title(chineseID))」")
        try check(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("asked-author").path),
            "补翻时不该联网问作者标题，但假 yt-dlp 收到了平铺列表请求"
        )
        print("title_backfill_check=passed（真实 QueueStore，旧格式队列：没看的英文旧条目补成「\(title(unwatchedID))」，已看的和中文的不动，没有问作者标题，用时 \(String(format: "%.2f", Date().timeIntervalSince(started))) 秒）")
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
