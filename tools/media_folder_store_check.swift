import Combine
import Foundation

/// 真实 `QueueStore(dataFile:mediaFolder:)` 装配：未连接不建目录、不启动下载、搬移后目录跟着变。
@main
struct MediaFolderStoreCheck {
    static func main() async throws {
        try await checkDisconnectedDoesNotCreateFolderOrStartDownload()
        try await checkRealVolumesPathStaysAbsent()
        try await checkMoveUpdatesStoreMediaFolder()
        try await checkDisconnectedSourceMoveIsRejected()
        try await checkDisconnectedDestinationMoveDoesNotCreate()
        try await checkLaunchRollsBackUnfinishedMove()
        try await checkUnreadableJournalBlocksMove()
        try await checkPreviousFolderShownUntilEmptied()
        try await checkSettingsMirrorSeesFailureAfterChange()
        print("media_folder_store_check=passed")
    }

    /// 可写的假卷根：旧代码会在这里建目录，这条检查必须失败。
    private static func checkDisconnectedDoesNotCreateFolderOrStartDownload() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let fakeVolumes = env.root.appendingPathComponent("Volumes", isDirectory: true)
        let missing = fakeVolumes.appendingPathComponent("不存在的卷/seesee", isDirectory: true)
        precondition(!FileManager.default.fileExists(atPath: missing.path))

        let id = UUID()
        try writeQueue(
            [
                queuedItem(id: id)
            ],
            to: env.dataFile
        )

        let store = await MainActor.run {
            QueueStore(
                dataFile: env.dataFile,
                mediaFolder: missing,
                defaults: env.defaults,
                mountedVolumeURLs: [URL(fileURLWithPath: "/")],
                volumesRoot: fakeVolumes
            )
        }

        await MainActor.run {
            precondition(store.isMediaFolderDisconnected, "注入空挂载列表后必须判定未连接")
            precondition(
                !FileManager.default.fileExists(atPath: missing.path),
                "未连接时不得创建片库目录"
            )
            precondition(
                !FileManager.default.fileExists(atPath: fakeVolumes.appendingPathComponent("不存在的卷").path),
                "未连接时不得在卷根留下同名空目录"
            )
            store.startDownload(for: id)
            precondition(store.items.first?.state == .queued, "未连接时不得进入下载")
            precondition(
                store.items.first?.progressLabel == MediaFolderCopy.disconnected,
                "排队状态应写成存放位置未连接"
            )
            precondition(
                !FileManager.default.fileExists(atPath: missing.path),
                "下载入口不得为了落盘而创建目录"
            )
        }
    }

    /// 测试路径：`/Volumes/不存在的卷/seesee` 判未连接，且构造后该路径不存在。
    private static func checkRealVolumesPathStaysAbsent() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let missing = URL(fileURLWithPath: "/Volumes/不存在的卷/seesee", isDirectory: true)
        precondition(
            MediaFolderAvailability.isDisconnected(
                missing,
                mountedVolumes: [URL(fileURLWithPath: "/")]
            )
        )
        let store = await MainActor.run {
            QueueStore(
                dataFile: env.dataFile,
                mediaFolder: missing,
                defaults: env.defaults,
                mountedVolumeURLs: [URL(fileURLWithPath: "/")]
            )
        }
        await MainActor.run {
            precondition(store.isMediaFolderDisconnected)
            precondition(!FileManager.default.fileExists(atPath: missing.path))
            precondition(!FileManager.default.fileExists(atPath: "/Volumes/不存在的卷"))
        }
    }

    private static func checkMoveUpdatesStoreMediaFolder() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let id = UUID()
        let video = env.mediaFolder.appendingPathComponent("\(id.uuidString).mp4")
        try Data("video-bytes-one".utf8).write(to: video)
        let item = WatchItem(
            id: id,
            urlString: "https://example.com/moved",
            title: "moved",
            author: "check",
            duration: 8,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            watchedAt: nil,
            state: .ready,
            progress: 1,
            progressLabel: "已下载",
            localFilePath: video.path,
            errorMessage: nil,
            playbackPosition: nil,
            chapters: nil,
            thumbnailFilePath: nil,
            subtitleFilePath: nil
        )
        try writeQueue([item], to: env.dataFile)

        let store = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: env.defaults)
        }
        let dest = env.root.appendingPathComponent("new-library", isDirectory: true)
        let result = await MainActor.run {
            store.moveMediaFolder(to: dest)
        }
        await MainActor.run {
            precondition(result == .success, "真实 QueueStore 搬移应当成功，实际 \(result)")
            precondition(
                store.mediaFolder.standardizedFileURL.path == dest.standardizedFileURL.path,
                "搬移后 store.mediaFolder 必须跟着变，视图只能读这个值"
            )
            precondition(store.items.first?.localFilePath == dest.appendingPathComponent("\(id.uuidString).mp4").path)
            precondition(FileManager.default.fileExists(atPath: video.path), "旧位置的文件必须留着")
            precondition(FileManager.default.fileExists(atPath: dest.appendingPathComponent("\(id.uuidString).mp4").path))
        }
    }

    /// 审查 1：QueueStore 默认搬移器也拒绝未连接的源片库。
    private static func checkDisconnectedSourceMoveIsRejected() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let fakeVolumes = env.root.appendingPathComponent("Volumes", isDirectory: true)
        let missing = fakeVolumes.appendingPathComponent("不存在的卷/seesee", isDirectory: true)
        try writeQueue([], to: env.dataFile)
        let dest = env.root.appendingPathComponent("new-library", isDirectory: true)

        let store = await MainActor.run {
            QueueStore(
                dataFile: env.dataFile,
                mediaFolder: missing,
                defaults: env.defaults,
                mountedVolumeURLs: [URL(fileURLWithPath: "/")],
                volumesRoot: fakeVolumes
            )
        }
        let result = await MainActor.run {
            store.moveMediaFolder(to: dest)
        }
        await MainActor.run {
            precondition(result == .failure(MediaFolderCopy.sourceDisconnected), "未连接源必须拒绝，实际 \(result)")
            precondition(store.mediaFolderMoveMessage == MediaFolderCopy.failure(MediaFolderCopy.sourceDisconnected))
            let leftover = try! JSONDecoder().decode([WatchItem].self, from: Data(contentsOf: env.dataFile))
            precondition(leftover.isEmpty, "未连接时不得改写队列条目")
            precondition(env.defaults.string(forKey: MediaFolderPreference.key) == nil)
            precondition(!FileManager.default.fileExists(atPath: dest.path))
        }
    }

    /// 审查 4：QueueStore 默认搬移器对未挂载目标不得建目录。
    private static func checkDisconnectedDestinationMoveDoesNotCreate() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let fakeVolumes = env.root.appendingPathComponent("Volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeVolumes, withIntermediateDirectories: true)
        let dest = fakeVolumes.appendingPathComponent("不存在的卷/seesee", isDirectory: true)
        try writeQueue([], to: env.dataFile)

        let store = await MainActor.run {
            QueueStore(
                dataFile: env.dataFile,
                mediaFolder: env.mediaFolder,
                defaults: env.defaults,
                mountedVolumeURLs: [URL(fileURLWithPath: "/")],
                volumesRoot: fakeVolumes
            )
        }
        let result = await MainActor.run {
            store.moveMediaFolder(to: dest)
        }
        await MainActor.run {
            precondition(
                result == .failure(MediaFolderCopy.destinationDisconnected),
                "目标未连接必须拒绝，实际 \(result)"
            )
            precondition(store.mediaFolderMoveMessage == MediaFolderCopy.failure(MediaFolderCopy.destinationDisconnected))
            precondition(!FileManager.default.fileExists(atPath: dest.path))
            precondition(!FileManager.default.fileExists(atPath: fakeVolumes.appendingPathComponent("不存在的卷").path))
        }
    }

    /// 上次搬移中断：启动时退回旧位置并提示一句，之后可以正常重新更改。
    private static func checkLaunchRollsBackUnfinishedMove() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let video = env.mediaFolder.appendingPathComponent("keep.mp4")
        try Data("video-bytes-one".utf8).write(to: video)
        try writeQueue([readyItem(localFilePath: video.path)], to: env.dataFile)
        let dest = env.root.appendingPathComponent("new-library", isDirectory: true)
        var mover = MediaLibraryMover(defaults: env.defaults)
        mover.interruptAfter = .afterCopyProgress(completed: 1)
        let interrupted = mover
        let first = await MainActor.run { () -> MediaLibraryMoveResult in
            let store = QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: env.defaults)
            return store.moveMediaFolder(to: dest, mover: interrupted)
        }
        precondition(first == .failure(MediaFolderCopy.interrupted))

        let relaunched = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: env.defaults)
        }
        let retry = await MainActor.run { () -> (String?, MediaLibraryMoveResult) in
            let message = relaunched.mediaFolderMoveMessage
            return (message, relaunched.moveMediaFolder(to: dest))
        }
        precondition(retry.0 == MediaFolderCopy.pendingMoveRolledBack, "启动时应提示上次没完成、仍用原位置，实际 \(String(describing: retry.0))")
        precondition(retry.1 == .success, "退回后重新更改应当成功，实际 \(retry.1)")
        precondition(FileManager.default.fileExists(atPath: video.path))
        precondition(FileManager.default.fileExists(atPath: dest.appendingPathComponent("keep.mp4").path))
    }

    /// 搬移记录读不出来：启动时提示，不改任何文件，也不让开始新的更改。
    private static func checkUnreadableJournalBlocksMove() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let video = env.mediaFolder.appendingPathComponent("keep.mp4")
        try Data("video-bytes-one".utf8).write(to: video)
        try writeQueue([readyItem(localFilePath: video.path)], to: env.dataFile)
        let journal = MediaFolderMoveJournal.url(beside: env.dataFile)
        try Data("from=/old\nto=/new\n".utf8).write(to: journal)
        let dest = env.root.appendingPathComponent("new-library", isDirectory: true)

        let observed = await MainActor.run { () -> (String?, MediaLibraryMoveResult, String?) in
            let store = QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: env.defaults)
            let atLaunch = store.mediaFolderMoveMessage
            let result = store.moveMediaFolder(to: dest)
            return (atLaunch, result, store.mediaFolderMoveMessage)
        }
        precondition(observed.0 == MediaFolderCopy.pendingMoveUnreadable, "实际 \(String(describing: observed.0))")
        precondition(observed.1 == .failure(MediaFolderCopy.pendingMoveUnreadable), "实际 \(observed.1)")
        precondition(observed.2 == MediaFolderCopy.failure(MediaFolderCopy.pendingMoveUnreadable))
        precondition(try! Data(contentsOf: journal) == Data("from=/old\nto=/new\n".utf8))
        precondition(FileManager.default.fileExists(atPath: video.path))
        precondition(!FileManager.default.fileExists(atPath: dest.path))
    }

    /// 切换后设置页显示旧位置那一行；旧位置在访达里删空后不再显示，记录也清掉。
    private static func checkPreviousFolderShownUntilEmptied() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let video = env.mediaFolder.appendingPathComponent("keep.mp4")
        try Data("video-bytes-one".utf8).write(to: video)
        try writeQueue([readyItem(localFilePath: video.path)], to: env.dataFile)
        let dest = env.root.appendingPathComponent("new-library", isDirectory: true)

        let store = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: env.defaults)
        }
        let seen = await MainActor.run { () -> (URL?, URL?) in
            let mirror = SettingsPageMirror()
            mirror.bind(store)
            precondition(store.previousMediaFolder == nil, "没切换过时不显示旧位置")
            precondition(store.moveMediaFolder(to: dest) == .success)
            return (store.previousMediaFolder, mirror.previous)
        }
        let expected = env.mediaFolder.standardizedFileURL.path
        precondition(seen.0?.path == expected, "切换后应显示旧位置，实际 \(String(describing: seen.0))")
        precondition(seen.1?.path == expected, "设置页应拿到旧位置，实际 \(String(describing: seen.1))")

        let reopened = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: dest, defaults: env.defaults).previousMediaFolder
        }
        precondition(reopened?.path == expected, "重新打开应用仍应显示旧位置")

        try FileManager.default.removeItem(at: video)
        let afterEmptied = await MainActor.run { () -> URL? in
            store.refreshPreviousMediaFolder()
            return store.previousMediaFolder
        }
        precondition(afterEmptied == nil, "旧位置删空后不再显示")
        precondition(env.defaults.string(forKey: QueueStore.previousMediaFolderKey) == nil, "删空后清掉记录")
    }

    /// 审查 5：设置页订赋值后的发布，看到的失败文案与 store 最终值一致。
    private static func checkSettingsMirrorSeesFailureAfterChange() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let id = UUID()
        let name = "\(id.uuidString).mp4"
        let video = env.mediaFolder.appendingPathComponent(name)
        try Data("video-bytes-one".utf8).write(to: video)
        try writeQueue([
            WatchItem(
                id: id,
                urlString: "https://example.com/conflict",
                title: "conflict",
                author: "check",
                duration: 8,
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                watchedAt: nil,
                state: .ready,
                progress: 1,
                progressLabel: "已下载",
                localFilePath: video.path,
                errorMessage: nil,
                playbackPosition: nil,
                chapters: nil,
                thumbnailFilePath: nil,
                subtitleFilePath: nil
            )
        ], to: env.dataFile)

        let dest = env.root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("different-existing".utf8).write(to: dest.appendingPathComponent(name))

        let observed = await MainActor.run { () -> (MediaLibraryMoveResult, String?, String?) in
            let store = QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder, defaults: env.defaults)
            let mirror = SettingsPageMirror()
            mirror.bind(store)
            let result = store.moveMediaFolder(to: dest)
            return (result, store.mediaFolderMoveMessage, mirror.failure)
        }
        guard case .failure(let reason) = observed.0 else {
            fatalError("冲突必须失败，实际 \(observed.0)")
        }
        let expected = MediaFolderCopy.failure(reason)
        precondition(observed.1 == expected, "store 最终失败文案必须是包装后的原因")
        precondition(
            observed.2 == expected,
            "设置页订赋值后发布，必须拿到与 store 一致的失败文案，实际 \(String(describing: observed.2))"
        )
        precondition(observed.1 == observed.2)
    }

    /// 与 `DigestSettingsLiveView` 相同：订 `$published`，不订 `objectWillChange`。
    @MainActor
    private final class SettingsPageMirror {
        var failure: String?
        var folder: URL?
        var previous: URL?
        private var bag = Set<AnyCancellable>()

        func bind(_ store: QueueStore) {
            store.$mediaFolderMoveMessage
                .sink { [weak self] in self?.failure = $0 }
                .store(in: &bag)
            store.$mediaFolder
                .sink { [weak self] in self?.folder = $0 }
                .store(in: &bag)
            store.$previousMediaFolder
                .sink { [weak self] in self?.previous = $0 }
                .store(in: &bag)
        }
    }

    private struct Env {
        let root: URL
        let mediaFolder: URL
        let dataFile: URL
        let defaults: UserDefaults
        let suite: String
    }

    private static func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-store-\(UUID().uuidString)", isDirectory: true)
        let mediaFolder = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        let suite = "media-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Env(
            root: root,
            mediaFolder: mediaFolder,
            dataFile: root.appendingPathComponent("queue.json"),
            defaults: defaults,
            suite: suite
        )
    }

    private static func writeQueue(_ items: [WatchItem], to dataFile: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: dataFile)
    }

    private static func readyItem(localFilePath: String) -> WatchItem {
        WatchItem(
            id: UUID(),
            urlString: "https://example.com/ready",
            title: "ready",
            author: "check",
            duration: 8,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            watchedAt: nil,
            state: .ready,
            progress: 1,
            progressLabel: "已下载",
            localFilePath: localFilePath,
            errorMessage: nil,
            playbackPosition: nil,
            chapters: nil,
            thumbnailFilePath: nil,
            subtitleFilePath: nil
        )
    }

    private static func queuedItem(id: UUID) -> WatchItem {
        WatchItem(
            id: id,
            urlString: "https://example.com/waiting",
            title: "waiting",
            author: "check",
            duration: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
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
    }
}
