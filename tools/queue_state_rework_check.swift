import AppKit
import Foundation

/// 审查退修回归：生产 QueueStore 入口，隔离队列，明确的播放器事件样本。
@main
struct QueueStateReworkCheck {
    enum Failed: Error { case check(String) }
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failed.check(message) }
    }

    @MainActor static func main() async throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "all"
        if mode == "backup" || mode == "all" { try await backupFailure() }
        if mode == "manual" || mode == "all" { try manualPlayback() }
        if mode == "automatic" || mode == "all" { try automaticPlayback() }
        if mode == "recovery" || mode == "all" { try continuousPlaybackRecovery() }
        print("queue_state_rework_check=passed mode=\(mode)")
    }

    struct Fixture {
        let root: URL
        let file: URL
        let media: URL
        let suite: String
        let id: UUID
        func cleanUp() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        @MainActor func store() -> QueueStore {
            QueueStore(dataFile: file, mediaFolder: media, defaults: UserDefaults(suiteName: suite)!, mountedVolumeURLs: [])
        }
    }

    static func fixture(_ fields: [String: Any] = [:]) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ss-state-\(UUID().uuidString)")
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let id = UUID()
        var item: [String: Any] = ["id": id.uuidString, "urlString": "https://example.invalid/state-check", "title": "状态退修样本", "author": "", "addedAt": "2026-10-01T00:00:00Z", "duration": 600, "state": "ready", "progress": 1, "progressLabel": "已下载"]
        item.merge(fields) { _, new in new }
        let file = root.appendingPathComponent("queue.json")
        try JSONSerialization.data(withJSONObject: [item], options: [.sortedKeys]).write(to: file)
        return Fixture(root: root, file: file, media: media, suite: "seesee.check.state-rework.\(UUID().uuidString)", id: id)
    }

    @MainActor static func backupFailure() async throws {
        let f = try fixture(["playbackPosition": 312.5]); defer { f.cleanUp() }
        let original = try Data(contentsOf: f.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path)
        let store = f.store()
        store.rename(f.id, to: "不应保存的名称")
        try await Task.sleep(nanoseconds: 800_000_000)
        try check(try Data(contentsOf: f.file) == original, "升级备份失败后延迟保存不能覆盖原文件")
        store.flushPendingSaves()
        try check(try Data(contentsOf: f.file) == original, "升级备份失败后强制保存不能覆盖原文件")
        try check(UserDefaults(suiteName: f.suite)!.integer(forKey: QueueUpgradeBackup.formatVersionKey) == 0, "备份失败不应记新版本")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
        let reloaded = f.store()
        reloaded.rename(f.id, to: "重载后成功保存")
        reloaded.flushPendingSaves()
        let backups = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(QueueUpgradeBackup.filePrefix) }
        try check(backups.count == 1, "下一次加载应留一份备份")
        let backup = try Data(contentsOf: backups[0])
        try check(backup == original, "下一次加载应先备份原文件")
        try check(try Data(contentsOf: f.file) != original, "重载备份成功后才允许保存")
        print("backupFailure: 延迟和强制保存均保留原件，重载备份后恢复保存")
    }

    /// 改自审查者 state-recovery-samples.swift：恢复权限不产生新的 started。
    @MainActor static func continuousPlaybackRecovery() throws {
        for manual in [false, true] {
            var fields: [String: Any] = ["hasPlayedThreeSeconds": false]
            if manual { fields["watchStatus"] = "to_watch" } else { fields["inInbox"] = true }
            let f = try fixture(fields); defer { f.cleanUp() }
            let original = try Data(contentsOf: f.file)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path)
            let store = f.store()
            store.handlePlaybackEvent(.started(at: 0), for: f.id)
            store.updatePlaybackPosition(2, for: f.id, whilePlaying: true)
            try check(!store.acceptsAgentWrites, "确认只读期间真实播放回报遭拒")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
            for seconds in [4.0, 6.0] {
                store.updatePlaybackPosition(seconds, for: f.id, whilePlaying: true)
                try check(store.item(with: f.id)?.status == (manual ? .toWatch : .inbox), "恢复后不足三秒，不能补算只读期间的播放")
            }
            store.updatePlaybackPosition(7, for: f.id, whilePlaying: true)
            try check(store.item(with: f.id)?.status == .watching, "恢复后首次回报起连续三秒，无需重新开始播放")
            try check(store.item(with: f.id)?.hasPlayedThreeSeconds == true, "恢复后须设置真实播放标记")
            try check(store.flushPendingSaves(), "恢复状态须真正保存")
            try check(f.store().item(with: f.id)?.status == .watching, "恢复状态重载不丢失")
            let backups = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(QueueUpgradeBackup.filePrefix) }
            try check(backups.count == 1 && Data(contentsOf: backups[0]) == original, "升级备份精确保留旧原件")
            print("continuousRecovery: manual=\(manual)，恢复后 4、6 秒不晋升，7 秒进入观看中并落盘，原件备份相同")
        }
    }

    @MainActor static func manualPlayback() throws {
        let f = try fixture(["watchStatus": "to_watch", "playbackPosition": 100]); defer { f.cleanUp() }
        let store = f.store()
        store.handlePlaybackEvent(.started(at: 100), for: f.id)
        store.updatePlaybackPosition(100, for: f.id, whilePlaying: true)
        store.updatePlaybackPosition(102, for: f.id, whilePlaying: true)
        store.handlePlaybackEvent(.seeked, for: f.id)
        store.updatePlaybackPosition(200, for: f.id, whilePlaying: true)
        store.handlePlaybackEvent(.started(at: 200), for: f.id)
        store.updatePlaybackPosition(202, for: f.id, whilePlaying: true)
        try check(store.items[0].status == .toWatch && store.items[0].statusIsManual, "快进后不足三秒不能清掉手动待看")
        store.handlePlaybackEvent(.paused, for: f.id)
        store.handlePlaybackEvent(.started(at: 202), for: f.id)
        store.updatePlaybackPosition(204, for: f.id, whilePlaying: true)
        try check(store.items[0].status == .toWatch, "两秒加暂停加两秒不算连续三秒")
        store.updatePlaybackPosition(205, for: f.id, whilePlaying: true)
        try check(store.items[0].status == .watching && !store.items[0].statusIsManual, "本段连续三秒应进入观看中")
        print("manualPlayback: 跳转和短暂停重置，连续三秒才进入观看中")
    }

    @MainActor static func automaticPlayback() throws {
        let f = try fixture(["inInbox": true, "hasPlayedThreeSeconds": false]); defer { f.cleanUp() }
        let store = f.store()
        store.updatePlaybackPosition(100, for: f.id, whilePlaying: false)
        try check(store.items[0].status == .inbox && store.items[0].playbackPosition == 100, "暂停跳转保留续播位置，收件箱状态不变")
        store.handlePlaybackEvent(.started(at: 100), for: f.id)
        store.updatePlaybackPosition(102, for: f.id, whilePlaying: true)
        store.handlePlaybackEvent(.paused, for: f.id)
        store.handlePlaybackEvent(.started(at: 102), for: f.id)
        store.updatePlaybackPosition(104, for: f.id, whilePlaying: true)
        try check(store.items[0].status == .inbox, "新条目两段各两秒仍在收件箱")
        store.updatePlaybackPosition(105, for: f.id, whilePlaying: true)
        try check(store.items[0].status == .watching, "新条目本段连续三秒进入观看中")
        store.handlePlaybackEvent(.seeked, for: f.id)
        store.updatePlaybackPosition(0, for: f.id, whilePlaying: false)
        try check(store.items[0].status == .watching, "已经真实观看的条目跳回零秒仍在观看中")
        store.flushPendingSaves()
        try check(f.store().items[0].status == .watching, "真实播放标记须持久化")
        let old = try fixture(["playbackPosition": 100]); defer { old.cleanUp() }
        try check(old.store().items[0].status == .watching, "没有新标记的旧条目仍按旧进度推算")
        print("automaticPlayback: 暂停跳转不变状态，真实播放标记持久化，兼容旧队列")
    }
}
