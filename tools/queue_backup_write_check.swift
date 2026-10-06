import AppKit
import Foundation

/// 复用复审样本，通过生产 QueueStore 的写入、备份和重载边界验证数据保护。
@main
struct QueueBackupWriteCheck {
    enum Failed: Error { case check(String) }
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failed.check(message) }
    }

    struct Fixture {
        let root: URL
        let file: URL
        let media: URL
        let suite: String
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
        @MainActor func store() -> QueueStore {
            QueueStore(dataFile: file, mediaFolder: media, defaults: defaults, mountedVolumeURLs: [])
        }
        func permissions(_ value: Int) throws {
            try FileManager.default.setAttributes([.posixPermissions: value], ofItemAtPath: root.path)
        }
        func cleanUp() {
            try? permissions(0o755)
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    static func fixture(_ fields: [String: Any] = [:]) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/ss-backup-write-\(UUID().uuidString)")
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let f = Fixture(root: root, file: root.appendingPathComponent("queue.json"), media: media, suite: "seesee.check.backup-write.\(UUID().uuidString)")
        let localFile = media.appendingPathComponent("\(f.id.uuidString).mp4")
        try Data("删除保护样本".utf8).write(to: localFile)
        var item: [String: Any] = [
            "id": f.id.uuidString, "urlString": "https://example.invalid/review",
            "title": "样本标题", "author": "样本频道", "duration": 600,
            "addedAt": "2026-09-01T08:00:00Z", "state": "ready", "progress": 1,
            "progressLabel": "已下载", "playbackPosition": 312.5,
            "chapters": [["title": "开场", "startTime": 0, "endTime": 120]],
            "localFilePath": localFile.path, "thumbnailFilePath": "", "subtitleFilePath": "", "errorMessage": "旧错误样本"
        ]
        item.merge(fields) { _, new in new }
        try JSONSerialization.data(withJSONObject: [item], options: [.sortedKeys]).write(to: f.file)
        return f
    }

    @MainActor static func main() async throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "all"
        if mode == "recover" || mode == "all" { try await recoversWithoutReload() }
        if mode == "flush" || mode == "all" { try flushRetriesBackup() }
        if mode == "resume" || mode == "all" { try resumesPlaybackProofAfterRecovery() }
        if mode == "readonly" || mode == "all" { try await rejectsWritesWhileReadOnly() }
        print("queue_backup_write_check=passed mode=\(mode)")
    }

    @MainActor static func recoversWithoutReload() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let original = try Data(contentsOf: f.file)
        try f.permissions(0o555)
        let store = f.store()
        try check(f.defaults.integer(forKey: QueueUpgradeBackup.formatVersionKey) == 0, "确认初始化升级备份真实失败")
        try f.permissions(0o755)
        store.rename(f.id, to: "备份失败以后改名")
        store.updatePlaybackPosition(420, for: f.id, whilePlaying: false)
        _ = store.addBatch([URL(string: "https://example.invalid/review-new-link")!], activatesApp: false)
        try await Task.sleep(nanoseconds: 800_000_000)
        let reloaded = f.store()
        try check(reloaded.items.count == 2 && reloaded.items.contains { $0.urlString.contains("review-new-link") }, "目录恢复后新链接应自动备份并保存，重载不能丢失")
        try check(reloaded.item(with: f.id)?.customTitle == "备份失败以后改名" && reloaded.item(with: f.id)?.playbackPosition == 420, "目录恢复后的改名和进度须保住")
        try check(store.acceptsAgentWrites && store.queueWriteWarning == nil, "自动恢复以后 agent 和界面使用同一可写状态，横幅消失")
        let backups = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(QueueUpgradeBackup.filePrefix) }
        try check(backups.count == 1 && (try Data(contentsOf: backups[0])) == original, "必须先精确保留旧原件，再落盘恢复后的改动")
        print("recover: 目录恢复后无需重载，自动备份原件；链接、标题、进度经延迟保存和重载保住")
    }

    @MainActor static func flushRetriesBackup() throws {
        let f = try fixture(); defer { f.cleanUp() }
        let original = try Data(contentsOf: f.file)
        try f.permissions(0o555)
        let store = f.store()
        try f.permissions(0o755)
        store.flushPendingSaves()
        try check(f.defaults.integer(forKey: QueueUpgradeBackup.formatVersionKey) == QueueUpgradeBackup.currentFormatVersion, "退出前 flush 必须重试升级备份，不得继续静默丢掉待保存内容")
        let backups = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(QueueUpgradeBackup.filePrefix) }
        try check(backups.count == 1 && (try Data(contentsOf: backups[0])) == original, "flush 保存前也必须备份磁盘原件")
        print("flush: 目录恢复后强制保存也先重试备份，再保存本次队列")
    }

    @MainActor static func rejectsWritesWhileReadOnly() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let original = try Data(contentsOf: f.file)
        try f.permissions(0o555)
        let store = f.store()
        let initial = store.items
        try check(store.queueWriteWarning == "无法备份数据，改动不会保存", "初始化备份失败即显示持续横幅")
        store.rename(f.id, to: "不得改名")
        try check(store.items == initial, "备份仍失败时必须在改内存前拒绝改名")
        try check(store.lastIntakeError == "无法备份数据，改动不会保存", "改名被拒必须给出明确失败提示")
        store.lastIntakeError = nil
        let result = store.addBatch([URL(string: "https://example.invalid/refused-link")!], activatesApp: false)
        try check(result.isEmpty && store.items == initial, "备份仍失败时不得加入新条目或声称成功")
        try check(store.intakeNotice?.title.contains("已加入") != true, "备份失败不能显示已加入")
        store.toggleWatched(f.id)
        _ = store.moveItems([f.id], to: .archived)
        store.remove(f.id)
        try check(store.items == initial, "只读时改状态和删除不得改动内存")
        try check(FileManager.default.fileExists(atPath: initial[0].localFilePath!), "拒绝删除必须保留本地文件")
        store.lastIntakeError = nil
        store.updatePlaybackPosition(420, for: f.id, whilePlaying: false)
        try check(store.items == initial && store.lastIntakeError == nil, "只读时续播位置不改动、不另弹提示")
        store.dismissIntakeNotice()
        try check(store.queueWriteWarning == "无法备份数据，改动不会保存", "关闭临时提示不应移除持续横幅")
        try await Task.sleep(nanoseconds: 800_000_000)
        store.flushPendingSaves()
        try check(try Data(contentsOf: f.file) == original, "持续备份失败时原队列必须保持逐字节一致")
        try check(!store.acceptsAgentWrites && store.queueWriteWarning == "无法备份数据，改动不会保存", "agent 采用同一只读状态，持续横幅不因时间或重试消失")
        print("readonly: 加入、改名、状态、删除均拒绝；无成功提示，续播静默拒绝，原件和媒体未动")
    }
    @MainActor static func resumesPlaybackProofAfterRecovery() throws {
        let f = try fixture(["inInbox": true, "hasPlayedThreeSeconds": false]); defer { f.cleanUp() }
        try f.permissions(0o555)
        let store = f.store()
        store.handlePlaybackEvent(.started(at: 100), for: f.id)
        store.updatePlaybackPosition(102, for: f.id, whilePlaying: true)
        store.handlePlaybackEvent(.paused, for: f.id)
        store.handlePlaybackEvent(.started(at: 102), for: f.id)
        store.updatePlaybackPosition(104, for: f.id, whilePlaying: true)
        try check(store.item(with: f.id)?.status == .inbox, "只读期间不能改变队列状态")
        try f.permissions(0o755)
        store.updatePlaybackPosition(104.5, for: f.id, whilePlaying: true)
        try check(store.item(with: f.id)?.status == .inbox, "恢复写入后仍不能把两段各两秒加在一起")
        store.updatePlaybackPosition(105, for: f.id, whilePlaying: true)
        try check(store.item(with: f.id)?.status == .inbox, "只读期间的播放不补算，恢复后只有半秒")
        store.handlePlaybackEvent(.paused, for: f.id)
        store.updatePlaybackPosition(106, for: f.id, whilePlaying: true)
        store.updatePlaybackPosition(108.5, for: f.id, whilePlaying: true)
        try check(store.item(with: f.id)?.status == .inbox, "暂停仍清零，新的真实播放回报不足三秒不晋升")
        store.updatePlaybackPosition(109, for: f.id, whilePlaying: true)
        try check(store.item(with: f.id)?.status == .watching, "恢复后本段连续三秒才进入观看中")
        store.flushPendingSaves()
        try check(f.store().item(with: f.id)?.status == .watching, "恢复后的真实观看状态必须落盘")
        print("resume: 只读期间不补算；恢复后真实回报重新起算，暂停清零，本段满三秒才晋升")
    }

}
