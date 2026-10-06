import AppKit
import Foundation

/// 待播清单状态的迁移检查：经生产代码 `QueueStore` 读一份旧格式的 queue.json。
/// 断言：第一次保存前留了一份带日期的备份，内容和原文件一字不差；旧条目按推算规则得出状态
/// （有 watchedAt 的已看完、有观看进度的观看中、其余待看）；存出去再读回来，旧条目的每个键和值都在；
/// 再次启动不重复备份；新链接进收件箱，播放后自动变观看中，界面动作算手动。
@main
struct QueueStatusMigrationCheck {
    static let watchedID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let watchingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let plainID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    static func main() async throws {
        // 粘贴入口会调 NSApp.activate；检查程序里没有 NSApplication 时 NSApp 是 nil。
        _ = await MainActor.run { NSApplication.shared }
        try await title101RoundTrip()
        let env = try makeEnv()
        defer {
            try? FileManager.default.removeItem(at: env.root)
            UserDefaults.standard.removePersistentDomain(forName: env.defaultsSuite)
        }
        let original = oldFormatQueue()
        try original.write(to: env.dataFile)
        let defaults = UserDefaults(suiteName: env.defaultsSuite)!

        let store = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: defaults)
        }

        // 1. 状态推算。
        await MainActor.run {
            let byID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
            precondition(byID.count == 3, "三条旧条目都读进来了：\(byID.count)")
            precondition(byID[watchedID]?.status == .watched, "有 watchedAt 的旧条目是已看完：\(String(describing: byID[watchedID]?.status))")
            precondition(byID[watchingID]?.status == .watching, "有观看进度的旧条目是观看中：\(String(describing: byID[watchingID]?.status))")
            precondition(byID[plainID]?.status == .toWatch, "其余旧条目是待看：\(String(describing: byID[plainID]?.status))")
            precondition(store.items.allSatisfy { !$0.statusIsManual }, "旧条目都不算手动挪过")
            precondition(store.queueItems.map(\.id) == [watchingID, plainID], "待播清单是观看中和待看两条：\(store.queueItems.map(\.id))")
            precondition(store.archivedItems.map(\.id) == [watchedID], "「已看」分组是已看完那一条")
        }

        // 2. 第一次保存前留了备份，内容和原文件一样。
        let backups = try backupFiles(in: env.root)
        precondition(backups.count == 1, "第一次保存前留一份备份：\(backups.map(\.lastPathComponent))")
        let name = backups[0].lastPathComponent
        precondition(name.range(of: #"^queue-升级前备份-\d{8}-\d{6}\.json$"#, options: .regularExpression) != nil, "备份文件名带日期：\(name)")
        let backupData = try Data(contentsOf: backups[0])
        precondition(backupData == original, "备份内容和旧 queue.json 一字不差")

        // 3. 存出去再读回来，旧条目的每个键和值都在。
        await MainActor.run { store.flushPendingSaves() }
        let savedObjects = try queueObjects(Data(contentsOf: env.dataFile))
        let originalObjects = try queueObjects(original)
        for old in originalObjects {
            let id = old["id"] as! String
            guard let saved = savedObjects.first(where: { $0["id"] as? String == id }) else {
                preconditionFailure("存盘后条目 \(id) 不见了")
            }
            for (key, value) in old {
                guard let savedValue = saved[key] else { preconditionFailure("存盘后条目 \(id) 少了键 \(key)") }
                precondition((savedValue as AnyObject).isEqual(value), "存盘后条目 \(id) 的 \(key) 变了：\(value) → \(savedValue)")
            }
        }

        // 4. 再次启动：状态一样，不再备份。
        let reloaded = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: defaults)
        }
        await MainActor.run {
            let statuses = Dictionary(uniqueKeysWithValues: reloaded.items.map { ($0.id, $0.status) })
            precondition(statuses == [watchedID: .watched, watchingID: .watching, plainID: .toWatch], "读回来状态不变：\(statuses)")
        }
        let backupsAfterReload = try backupFiles(in: env.root).count
        precondition(backupsAfterReload == 1, "再次启动不重复备份")

        // 5. 状态随动作变化。
        await MainActor.run {
            reloaded.accept(rawValue: "https://example.com/watch/new-video")
            guard let added = reloaded.items.first(where: { $0.urlString == "https://example.com/watch/new-video" }) else {
                preconditionFailure("粘贴的新链接应加入清单")
            }
            precondition(added.status == .inbox && !added.statusIsManual, "新链接进收件箱，不算手动：\(added.status)")

            reloaded.updatePlaybackPosition(42, for: added.id)
            precondition(reloaded.items.first { $0.id == added.id }?.status == .inbox, "暂停跳转不改变收件箱状态")
            reloaded.handlePlaybackEvent(.started(at: 42), for: added.id)
            reloaded.updatePlaybackPosition(45, for: added.id, whilePlaying: true)
            precondition(reloaded.items.first { $0.id == added.id }?.status == .watching, "连续真实播放三秒后自动变观看中")

            reloaded.toggleWatched(plainID)
            let marked = reloaded.items.first { $0.id == plainID }!
            precondition(marked.status == .watched && marked.statusIsManual && marked.watchedAt != nil, "界面「标记已看」算手动挪到已看完")

            reloaded.toggleWatched(watchedID)
            let restored = reloaded.items.first { $0.id == watchedID }!
            precondition(restored.status == .toWatch && restored.statusIsManual && restored.watchedAt == nil, "界面「移回队列」算手动挪到待看，清掉 watchedAt")
            reloaded.updatePlaybackPosition(80, for: watchedID)
            precondition(reloaded.items.first { $0.id == watchedID }?.status == .toWatch, "手动挪过的条目，播放进度不再改它的状态")

            reloaded.markWatched(added.id)
            let finished = reloaded.items.first { $0.id == added.id }!
            precondition(finished.status == .watched && finished.statusIsManual, "播放到结尾算手动挪到已看完")
            precondition(reloaded.archivedItems.contains { $0.id == plainID }, "已看完的条目在「已看」分组")
            precondition(reloaded.queueItems.contains { $0.id == watchedID }, "移回队列的条目在待播清单")
        }

        // 6. 手动挪到待看的条目，播放满 3 秒自动进观看中；拖进度不算播放。已看完满 30 天能算出来。
        await MainActor.run {
            reloaded.toggleWatched(plainID)
            precondition(reloaded.items.first { $0.id == plainID }?.status == .toWatch, "移回队列是手动待看")
            reloaded.updatePlaybackPosition(100, for: plainID)
            precondition(reloaded.items.first { $0.id == plainID }?.status == .toWatch, "拖进度不算播放，仍是待看")
            reloaded.handlePlaybackEvent(.started(at: 100), for: plainID)
            reloaded.updatePlaybackPosition(100, for: plainID, whilePlaying: true)
            reloaded.updatePlaybackPosition(102, for: plainID, whilePlaying: true)
            precondition(reloaded.items.first { $0.id == plainID }?.status == .toWatch, "播放不满 3 秒仍是待看")
            reloaded.updatePlaybackPosition(103.5, for: plainID, whilePlaying: true)
            let promoted = reloaded.items.first { $0.id == plainID }!
            precondition(promoted.status == .watching && !promoted.statusIsManual, "手动待看的条目播放满 3 秒自动进观看中")

            let finished = reloaded.items.first { $0.urlString == "https://example.com/watch/new-video" }!
            precondition(finished.isWatched(forAtLeastDays: 30, now: finished.watchedAt!.addingTimeInterval(30 * 86_400)), "已看完满 30 天")
            precondition(!finished.isWatched(forAtLeastDays: 30, now: finished.watchedAt!.addingTimeInterval(29 * 86_400)), "不满 30 天不算")
        }

        // 7. 手动定的状态存盘、读回来还在。
        await MainActor.run { reloaded.flushPendingSaves() }
        let third = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: defaults)
        }
        await MainActor.run {
            let restored = third.items.first { $0.id == watchedID }!
            precondition(restored.status == .toWatch && restored.statusIsManual, "手动状态存盘后读回来还在")
        }
        let backupsAfterThird = try backupFiles(in: env.root).count
        precondition(backupsAfterThird == 1, "第三次启动也不备份")

        // 8. 格式版本低于当前版本（例如 1.0.1 升到 1.1.0）时再备份一次。
        defaults.set(QueueUpgradeBackup.currentFormatVersion - 1, forKey: QueueUpgradeBackup.formatVersionKey)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: defaults)
        }
        let backupsAfterUpgrade = try backupFiles(in: env.root).count
        precondition(backupsAfterUpgrade == 2, "格式版本升级时再备份一次：\(backupsAfterUpgrade)")
        print("queue_status_migration_check=passed")
    }

    // MARK: - 夹具

    /// 1.0.1 的五字段原样往返；标题旧备份与格式 2 均不能跳过本次升级。
    static func title101RoundTrip() async throws {
        for previousVersion in [0, 2] {
            let env = try makeEnv()
            defer {
                try? FileManager.default.removeItem(at: env.root)
                UserDefaults.standard.removePersistentDomain(forName: env.defaultsSuite)
            }
            let defaults = UserDefaults(suiteName: env.defaultsSuite)!
            defaults.set(previousVersion, forKey: QueueUpgradeBackup.formatVersionKey)
            var item = try queueObjects(oldFormatQueue())[0]
            let fields = ["originalTitle": "Original 1.0.1 title", "translatedTitle": "中文标题", "translatedTitleSource": "author", "customTitle": "我的标题", "postText": "完整推文\n下一行也保留"]
            item.merge(fields) { _, new in new }
            let original = try JSONSerialization.data(withJSONObject: [item], options: [.sortedKeys])
            try original.write(to: env.dataFile)
            let oldTitleBackup = env.root.appendingPathComponent("queue-标题升级前备份-20261001-120000.json")
            let olderBytes = Data("先前的标题升级备份，不可替代本次原件".utf8)
            try olderBytes.write(to: oldTitleBackup)
            let store = await MainActor.run {
                QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: defaults)
            }
            let saved = await MainActor.run { store.flushPendingSaves() }
            precondition(saved, "1.0.1 样本必须真正保存")
            let backups = try backupFiles(in: env.root)
            precondition(backups.count == 1, "一次启动只产生一份通用格式备份")
            let backup = try Data(contentsOf: backups[0])
            precondition(backup == original, "从 1.0.1 升级备份必须是本次磁盘原件")
            let previousBackup = try Data(contentsOf: oldTitleBackup)
            precondition(previousBackup == olderBytes, "旧标题备份不得改变")
            let reloaded = await MainActor.run {
                QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: defaults)
            }
            _ = await MainActor.run { reloaded.flushPendingSaves() }
            let savedItem = try queueObjects(Data(contentsOf: env.dataFile))[0]
            for (key, value) in fields {
                precondition(savedItem[key] as? String == value, "1.0.1 字段读存重读丢失：\(key)")
            }
            let afterReopen = try backupFiles(in: env.root)
            precondition(afterReopen.count == 1, "再次启动不重复备份")
            precondition(defaults.integer(forKey: QueueUpgradeBackup.formatVersionKey) == QueueUpgradeBackup.currentFormatVersion, "备份成功后记录统一格式版本")
            print("title101RoundTrip: previousVersion=\(previousVersion)，五字段逐字不变，升级只备份一次，旧标题备份保留，重开不再备份")
        }
    }

    struct Env {
        let root: URL
        let mediaFolder: URL
        let dataFile: URL
        let defaultsSuite: String
    }

    static func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-status-\(UUID().uuidString)", isDirectory: true)
        let mediaFolder = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        return Env(
            root: root,
            mediaFolder: mediaFolder,
            dataFile: root.appendingPathComponent("queue.json"),
            defaultsSuite: "seesee.check.queue-status.\(UUID().uuidString)"
        )
    }

    /// 1.0.0 写出的格式：键按字母排序、日期是 ISO 8601、空值不写。
    static func oldFormatQueue() -> Data {
        let json = """
        [
          {
            "addedAt" : "2026-09-01T08:00:00Z",
            "author" : "频道甲",
            "chapters" : [ { "startTime" : 0, "title" : "开场" }, { "endTime" : 300, "startTime" : 120, "title" : "正题" } ],
            "duration" : 600,
            "id" : "11111111-1111-1111-1111-111111111111",
            "localFilePath" : "/tmp/none/11111111-1111-1111-1111-111111111111.mp4",
            "progress" : 1,
            "progressLabel" : "已下载",
            "state" : "ready",
            "subtitleFilePath" : "",
            "thumbnailFilePath" : "",
            "title" : "已经看完的视频",
            "urlString" : "https://www.youtube.com/watch?v=aaaaaaaaaaa",
            "watchedAt" : "2026-09-02T09:30:00Z"
          },
          {
            "addedAt" : "2026-09-03T08:00:00Z",
            "author" : "频道乙",
            "duration" : 1200,
            "id" : "22222222-2222-2222-2222-222222222222",
            "playbackPosition" : 312.5,
            "progress" : 1,
            "progressLabel" : "已下载",
            "state" : "ready",
            "title" : "看了一半的视频",
            "urlString" : "https://www.youtube.com/watch?v=bbbbbbbbbbb"
          },
          {
            "addedAt" : "2026-09-04T08:00:00Z",
            "author" : "",
            "errorMessage" : "网络断了",
            "id" : "33333333-3333-3333-3333-333333333333",
            "progress" : 0.25,
            "progressLabel" : "下载失败",
            "state" : "failed",
            "title" : "x.com",
            "urlString" : "https://x.com/someone/status/123"
          }
        ]
        """
        return Data(json.utf8)
    }

    static func queueObjects(_ data: Data) throws -> [[String: Any]] {
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            preconditionFailure("queue.json 不是对象数组")
        }
        return objects
    }

    static func backupFiles(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("queue-升级前备份-") }
    }
}
