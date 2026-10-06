import Foundation

/// 标题分开存以后的旧数据迁移：旧格式的 queue.json 读进来、存出去、再读回来，字段一个不少；
/// 第一次按新格式保存前，旧文件原样复制一份留在同目录，文件名带日期；第二次启动不再复制。
/// 从真实的 `QueueStore(dataFile:mediaFolder:)` 走，只用改动之前就有的接口，旧代码上也能编译运行，
/// 并在「没有留下旧文件的备份」这一条失败。
@main
@MainActor
struct TitleMigrationCheck {
    static let backupPrefix = QueueUpgradeBackup.filePrefix

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-migration-\(UUID().uuidString)", isDirectory: true)
        let mediaFolder = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataFile = root.appendingPathComponent("queue.json")

        // 旧版本写出的条目：键和值都按旧版 seesee 的写法。第一条是旧版本里用户改过的名字，现在没法区分，当作原标题。
        let legacyItems: [[String: Any]] = [
            [
                "id": "6F3B0C58-6A57-4C0B-9C35-2F0C7E1A0001",
                "urlString": "https://www.youtube.com/watch?v=legacy00001",
                "title": "我在旧版本里改过的名字",
                "author": "Blender Studio",
                "duration": 634.5,
                "addedAt": "2026-09-01T08:00:00Z",
                "watchedAt": "2026-09-02T08:00:00Z",
                "state": "ready",
                "progress": 1,
                "progressLabel": "已下载",
                "localFilePath": mediaFolder.appendingPathComponent("a.mp4").path,
                "playbackPosition": 321.25,
                "chapters": [["title": "Intro", "startTime": 0, "endTime": 60]],
                "thumbnailFilePath": "",
                "subtitleFilePath": mediaFolder.appendingPathComponent("a.zh-Hans.srt").path
            ],
            [
                "id": "6F3B0C58-6A57-4C0B-9C35-2F0C7E1A0002",
                "urlString": "https://x.com/someone/status/1234567890",
                "title": "someone - A tweet that yt-dlp cut off at seventy two characters and then...",
                "author": "someone",
                "addedAt": "2026-09-03T08:00:00Z",
                "state": "failed",
                "progress": 0.25,
                "progressLabel": "重试 3 次后失败",
                "errorMessage": "HTTP Error 403: Forbidden"
            ]
        ]
        let original = try JSONSerialization.data(withJSONObject: legacyItems, options: [.prettyPrinted, .sortedKeys])
        try original.write(to: dataFile)

        let suite = "seesee.check.title-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // 第一次启动：读进来，按统一格式备份后存出去。
        let store = QueueStore(dataFile: dataFile, mediaFolder: mediaFolder, defaults: defaults)
        try check(store.items.count == 2, "旧格式的 queue.json 没有全部读进来，读到 \(store.items.count) 条")
        store.flushPendingSaves()

        let backups = try backupFiles(in: root)
        try check(
            backups.count == 1,
            "第一次按新格式保存前，没有把旧的 queue.json 复制一份（同目录里应该有一个 \(backupPrefix)<日期>.json，实际 \(backups)）"
        )
        let backupName = backups[0]
        let datePart = String(backupName.dropFirst(backupPrefix.count))
        try check(
            datePart.range(of: #"^\d{8}-\d{6}\.json$"#, options: .regularExpression) != nil,
            "备份文件名里没有日期：\(backupName)"
        )
        let backupData = try Data(contentsOf: root.appendingPathComponent(backupName))
        try check(backupData == original, "备份不是旧文件的原样复制")

        // 存出去的新文件：旧条目的每个键和值都还在。
        let saved = try savedObjects(dataFile)
        try check(saved.count == legacyItems.count, "存出去以后条目数变了")
        for (old, new) in zip(legacyItems, saved) {
            for (key, value) in old {
                guard let newValue = new[key] else {
                    throw CheckFailure("存出去以后丢了字段 \(key)（条目 \(old["id"]!)）")
                }
                try check(
                    (value as AnyObject).isEqual(newValue),
                    "字段 \(key) 的值变了：旧 \(value)，新 \(newValue)"
                )
            }
            // 原来的 title 当作原标题。
            try check(
                (new["originalTitle"] as? String) == (old["title"] as? String),
                "旧条目的 title 没有记成原标题 originalTitle：\(new["originalTitle"] ?? "没有")"
            )
        }

        // 第二次启动：已经是新格式，不再复制；读回来和存出去的一致。
        let reopened = QueueStore(dataFile: dataFile, mediaFolder: mediaFolder, defaults: defaults)
        reopened.flushPendingSaves()
        try check(try backupFiles(in: root).count == 1, "第二次启动又复制了一份备份")
        try check(
            reopened.items.map(\.title) == legacyItems.map { $0["title"] as! String },
            "再读回来，显示的标题变了：\(reopened.items.map(\.title))"
        )
        let resaved = try savedObjects(dataFile)
        try check(
            (resaved as NSArray).isEqual(to: saved),
            "第二次存出去的内容和第一次不同"
        )

        print("title_migration_check=passed（旧 queue.json 原样备份一次；读进来、存出去、再读回来，字段一个不少；旧 title 记成原标题）")
    }

    private static func backupFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(backupPrefix) }
            .sorted()
    }

    private static func savedObjects(_ dataFile: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: dataFile)
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CheckFailure("存出去的 queue.json 不是条目数组")
        }
        return objects
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String) throws {
    if try !condition() { throw CheckFailure(message()) }
}
