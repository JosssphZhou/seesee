import Foundation

/// 旧格式 queue.json 的升级前备份写不成时，不能拿新格式覆盖原文件。从审查者的样本改来。
/// 1. 读入时目录不可写、备份没写成；之后目录恢复可写，用户改名：保存前先补上备份（和原文件字节一样），
///    再保存改名，续播进度还在。
/// 2. 目录一直不可写：改名在改内存之前就被拒绝，并提示「无法备份数据，改动不会保存」；queue.json 原样。
/// 只用改动之前就有的接口，在 73d7088 上也能编译运行，并在断言处失败。

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
    if !condition() { throw CheckFailure(description: message()) }
}

@main
@MainActor
struct TitleBackupFailureCheck {
    static func main() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("title-backup-failure-\(UUID().uuidString)")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.appendingPathComponent("recovers").path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.appendingPathComponent("stays").path)
            try? fm.removeItem(at: scratch)
        }
        // 两种情形都跑完再报，旧代码上能同时看到两处失败。
        var failures: [String] = []
        do { try recoversAfterDirectoryBecomesWritable(root: scratch.appendingPathComponent("recovers")) } catch {
            failures.append("恢复可写：\(error)")
        }
        do { try refusesWritesWhileBackupFails(root: scratch.appendingPathComponent("stays")) } catch {
            failures.append("一直不可写：\(error)")
        }
        guard failures.isEmpty else { throw CheckFailure(description: failures.joined(separator: "\n")) }
        print("title_backup_failure_check=passed（备份写不成时不覆盖旧队列；目录恢复可写后先补备份再保存，改动保住；一直写不成时改名被拒、给出提示、文件原样）")
    }

    /// 旧格式队列：一个已下载的条目，带续播进度。
    private static func seed(root: URL) throws -> (URL, URL, UUID, Data) {
        let fm = FileManager.default
        let media = root.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("queue.json")
        let id = UUID()
        let old: [[String: Any]] = [[
            "id": id.uuidString, "urlString": "https://example.com/legacy", "title": "旧标题", "author": "作者",
            "addedAt": "2026-09-01T08:00:00Z", "state": "ready", "progress": 1, "progressLabel": "已下载",
            "playbackPosition": 321.25, "chapters": [Any](), "thumbnailFilePath": "", "subtitleFilePath": ""
        ]]
        let before = try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys])
        try before.write(to: file)
        return (file, media, id, before)
    }

    private static func backups(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(TitleFieldsMigration.backupPrefix) }
    }

    private static func recoversAfterDirectoryBecomesWritable(root: URL) throws {
        let fm = FileManager.default
        let (file, media, id, before) = try seed(root: root)
        let suite = "ai.openmy.seesee.tests.backup-failure." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let store = QueueStore(dataFile: file, mediaFolder: media, defaults: defaults)
        let noBackups = try backups(in: root).isEmpty
        try check(noBackups, "目录不可写时不该有备份文件")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        store.rename(id, to: "更新后的标题")
        store.flushPendingSaves()
        let found = try backups(in: root)
        try check(found.count == 1, "目录恢复可写后，保存前应先补上升级前备份，实际 \(found)")
        let backupData = try Data(contentsOf: root.appendingPathComponent(found[0]))
        try check(backupData == before, "补上的备份不是旧文件的原样复制")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        try check(saved?.first?["title"] as? String == "更新后的标题", "补上备份以后，改名应照常保存：\(saved?.first?["title"] ?? "没有")")
        try check(saved?.first?["playbackPosition"] as? Double == 321.25, "续播进度应还在")
    }

    private static func refusesWritesWhileBackupFails(root: URL) throws {
        let fm = FileManager.default
        let (file, media, id, before) = try seed(root: root)
        let suite = "ai.openmy.seesee.tests.backup-failure." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let store = QueueStore(dataFile: file, mediaFolder: media, defaults: defaults)

        store.rename(id, to: "更新后的标题")
        let title = store.items.first { $0.id == id }?.title ?? "条目不见了"
        try check(title == "旧标题", "备份写不成时改名应在改内存之前被拒绝，现在内存里是「\(title)」")
        try check(
            store.intakeNotice?.detail == "无法备份数据，改动不会保存",
            "改名被拒时应提示「无法备份数据，改动不会保存」，实际 \(store.intakeNotice.map { "\($0.title) \($0.detail)" } ?? "没有提示")"
        )
        store.updatePlaybackPosition(400, for: id)
        store.flushPendingSaves()
        let after = try Data(contentsOf: file)
        try check(after == before, "备份写不成时 queue.json 应原样")
        let noBackups = try backups(in: root).isEmpty
        try check(noBackups, "目录不可写时不该有备份文件")
    }
}
