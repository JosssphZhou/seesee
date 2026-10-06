import Foundation

/// 搬移模块本身：复制、核对、切换，旧位置一个文件都不删；失败或没做完时按复制前清单退回。
@main
struct MediaLibraryMoverCheck {
    static func main() throws {
        checkAvailability()
        checkPreferenceDefault()
        checkLaunchArguments()
        try checkSuccessfulMoveKeepsSource()
        try checkCorruptCopyRollsBack()
        try checkConflictAborts()
        try checkDownloadBlock()
        try checkSameFolderNoOp()
        try checkNestedLocationsRefused()
        try checkDisconnectedSourceIsNotEmptyLibrary()
        try checkMissingSourceFails()
        try checkEnumerationErrorFails()
        try checkCopyThrowLeavesNoResidueAndCanRetry()
        try checkDisconnectedDestinationDoesNotCreate()
        try checkCorruptQueueRefusedBeforeAnyWrite()
        try checkJournalListsOnlyFilesThisRunWrites()
        try checkRollbackKeepsPreexistingDestinationFiles()
        try checkRollbackCleanupFailureKeepsJournalAndRetries()
        try checkRollbackWithDestinationDisconnected()
        try checkUnreadableJournalTouchesNothing()
        try checkMoveBackToOldLocation()
        print("media_library_mover_check=passed")
    }


    private static func checkAvailability() {
        let root = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let missing = URL(fileURLWithPath: "/Volumes/不存在的卷/seesee", isDirectory: true)
        let mounted = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Volumes/外置硬盘")]
        precondition(
            MediaFolderAvailability.isDisconnected(missing, mountedVolumes: mounted, volumesRoot: root),
            "未挂载的 /Volumes/不存在的卷 必须判为未连接"
        )

        let connected = URL(fileURLWithPath: "/Volumes/外置硬盘/seesee", isDirectory: true)
        precondition(
            !MediaFolderAvailability.isDisconnected(connected, mountedVolumes: mounted, volumesRoot: root),
            "已挂载卷上的目录不得判为未连接"
        )

        let movies = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/seesee", isDirectory: true)
        precondition(
            !MediaFolderAvailability.isDisconnected(movies, mountedVolumes: mounted),
            "家目录片库不是未连接"
        )

        let fakeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-avail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeRoot) }
        let fakeVolumes = fakeRoot.appendingPathComponent("Volumes", isDirectory: true)
        let fakeMissing = fakeVolumes.appendingPathComponent("不存在的卷/seesee", isDirectory: true)
        precondition(
            MediaFolderAvailability.isDisconnected(
                fakeMissing,
                mountedVolumes: [URL(fileURLWithPath: "/")],
                volumesRoot: fakeVolumes
            ),
            "注入挂载列表后，假卷根下的缺失卷也是未连接"
        )
    }

    private static func checkPreferenceDefault() {
        let suite = "media-folder-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(MediaFolderPreference.resolve(defaults: defaults) == nil, "没设过时没有自定义路径")
        let dest = URL(fileURLWithPath: "/tmp/seesee-library", isDirectory: true)
        MediaFolderPreference.save(dest, defaults: defaults)
        precondition(defaults.string(forKey: "MediaFolderPath") == dest.standardizedFileURL.path)
        precondition(MediaFolderPreference.resolve(defaults: defaults)?.path == dest.standardizedFileURL.path)
    }

    private static func checkLaunchArguments() {
        let dest = MediaFolderLaunchArguments.moveDestination(
            from: ["seesee", "--move-media-folder", "/tmp/seesee-dest"]
        )
        precondition(dest?.path == URL(fileURLWithPath: "/tmp/seesee-dest", isDirectory: true).path)
        precondition(MediaFolderLaunchArguments.moveDestination(from: ["seesee"]) == nil)
        precondition(
            MediaFolderLaunchArguments.moveDestination(from: ["seesee", "--move-media-folder"]) == nil,
            "缺目标路径时不搬"
        )
    }

    // MARK: - 成功与失败

    private static func checkSuccessfulMoveKeepsSource() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }

        let id = UUID()
        let video = env.source.appendingPathComponent("\(id.uuidString).mp4")
        let thumb = env.source.appendingPathComponent("\(id.uuidString).jpg")
        let subtitle = env.source.appendingPathComponent("\(id.uuidString).zh.srt")
        let nested = env.source.appendingPathComponent("notes/readme.txt")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("video-bytes-one".utf8).write(to: video)
        try Data("thumb-bytes".utf8).write(to: thumb)
        try Data("subtitle-line".utf8).write(to: subtitle)
        try Data("nested-note".utf8).write(to: nested)
        try Data("skip-me".utf8).write(to: env.source.appendingPathComponent(".DS_Store"))
        try writeQueue([sampleItem(id: id, local: video.path, thumbnail: thumb.path, subtitle: subtitle.path)], env)
        let originalQueue = try Data(contentsOf: env.dataFile)

        var progressEvents: [MediaLibraryMoveProgress] = []
        let result = MediaLibraryMover(defaults: env.defaults, now: { env.now }).move(
            from: env.source,
            to: env.destination,
            dataFile: env.dataFile,
            hasActiveDownload: false
        ) { progressEvents.append($0) }

        precondition(result == .success, "搬移应当成功，实际 \(result)")
        precondition(progressEvents.last?.completed == 4 && progressEvents.last?.total == 4)
        for file in [video, thumb, subtitle, nested] {
            let relative = MediaFolderPaths.relativePath(of: file, to: env.source)
            let copy = env.destination.appendingPathComponent(relative)
            precondition(FileManager.default.fileExists(atPath: file.path), "旧位置的 \(relative) 必须还在")
            precondition(shasum(copy) == shasum(file), "新位置的 \(relative) 必须与旧位置一致")
        }
        precondition(!FileManager.default.fileExists(atPath: env.destination.appendingPathComponent(".DS_Store").path))

        let rewritten = try loadItems(env)
        precondition(rewritten[0].localFilePath == env.destination.appendingPathComponent("\(id.uuidString).mp4").path)
        precondition(rewritten[0].thumbnailFilePath == env.destination.appendingPathComponent("\(id.uuidString).jpg").path)
        precondition(rewritten[0].subtitleFilePath == env.destination.appendingPathComponent("\(id.uuidString).zh.srt").path)

        let backup = env.support.appendingPathComponent("queue.json.bak-\(backupStamp(env.now))")
        precondition(try! Data(contentsOf: backup) == originalQueue, "备份必须是改写前的内容")
        precondition(env.preference == env.destination.standardizedFileURL.path)
        precondition(!env.journalExists, "切换完成后必须删掉搬移记录")
    }

    private static func checkCorruptCopyRollsBack() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let originalQueue = try Data(contentsOf: env.dataFile)

        var mover = MediaLibraryMover(defaults: env.defaults, now: { env.now })
        mover.copyItem = { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            try Data("corrupted-after-copy".utf8).write(to: to)
        }
        let result = mover.move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        guard case .failure(let reason) = result else {
            fatalError("复制后内容被改坏必须失败，实际 \(result)")
        }
        precondition(reason.contains("核对失败"), "失败原因应说明核对失败，实际 \(reason)")
        assertSourceIntact(library)
        precondition(try! Data(contentsOf: env.dataFile) == originalQueue, "失败后 queue.json 不得改")
        precondition(env.preference == nil, "失败后设置不得改")
        precondition(!FileManager.default.fileExists(atPath: env.destination.path), "失败后新位置不得残留")
        precondition(!env.journalExists)
        precondition(try! env.backupFiles().isEmpty, "核对失败时还没到备份这一步")
    }

    private static func checkConflictAborts() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let name = library.sourceFiles[0].lastPathComponent
        try FileManager.default.createDirectory(at: env.destination, withIntermediateDirectories: true)
        try Data("different-existing".utf8).write(to: env.destination.appendingPathComponent(name))
        let originalQueue = try Data(contentsOf: env.dataFile)

        let result = MediaLibraryMover(defaults: env.defaults, now: { env.now })
            .move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        guard case .failure(let reason) = result else {
            fatalError("同名不同内容必须中止，实际 \(result)")
        }
        precondition(reason.contains("没有覆盖"))
        assertSourceIntact(library)
        precondition(try! Data(contentsOf: env.destination.appendingPathComponent(name)) == Data("different-existing".utf8))
        precondition(try! FileManager.default.contentsOfDirectory(atPath: env.destination.path) == [name], "冲突时一个文件都不复制")
        precondition(try! Data(contentsOf: env.dataFile) == originalQueue)
        precondition(env.preference == nil)
        precondition(!env.journalExists, "准备阶段就中止，不写搬移记录")
    }

    private static func checkDownloadBlock() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let result = MediaLibraryMover(defaults: env.defaults)
            .move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: true)
        precondition(result == .failure(MediaFolderCopy.downloadingBlock))
        precondition(!FileManager.default.fileExists(atPath: env.destination.path))
    }

    private static func checkSameFolderNoOp() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let result = MediaLibraryMover(defaults: env.defaults)
            .move(from: env.source, to: env.source, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(result == .noOp)
        assertSourceIntact(library)
        precondition(env.preference == nil)
    }

    /// 新位置在片库里面、或包含片库：都拒绝；退回时记录里出现这种关系也不删任何东西。
    private static func checkNestedLocationsRefused() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let inside = env.source.appendingPathComponent("sub", isDirectory: true)
        let intoChild = MediaLibraryMover(defaults: env.defaults)
            .move(from: env.source, to: inside, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(intoChild == .failure(MediaFolderCopy.destinationOverlapsLibrary), "实际 \(intoChild)")
        precondition(!FileManager.default.fileExists(atPath: inside.path))
        let intoParent = MediaLibraryMover(defaults: env.defaults)
            .move(from: env.source, to: env.root, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(intoParent == .failure(MediaFolderCopy.destinationOverlapsLibrary), "实际 \(intoParent)")
        precondition(!MediaFolderPaths.overlap(env.source, env.root.appendingPathComponent("from-other")), "同名前缀的兄弟目录不算包含")

        // 伪造一份新位置包含旧位置、清单指向旧位置文件的记录：退回不得删。
        let target = library.sourceFiles[0]
        let forged = MediaFolderMoveJournal(
            source: env.source.path,
            destination: env.root.path,
            createdDestination: false,
            copiedFiles: ["from/\(target.lastPathComponent)"],
            createdDirectories: [],
            queueBackup: nil,
            previousPreference: nil
        )
        try forged.write(beside: env.dataFile)
        let outcome = MediaFolderMoveRecovery.rollBackPendingMove(
            beside: env.dataFile,
            defaults: env.defaults,
            mountedVolumes: [URL(fileURLWithPath: "/")]
        )
        precondition(outcome == .needsAttention(MediaFolderCopy.pendingMoveUnreadable), "实际 \(outcome)")
        precondition(env.journalExists)
        assertSourceIntact(library)
    }

    /// 未挂载源卷不得当空片库成功搬移。
    private static func checkDisconnectedSourceIsNotEmptyLibrary() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let fakeVolumes = env.root.appendingPathComponent("Volumes", isDirectory: true)
        let missing = fakeVolumes.appendingPathComponent("不存在的卷/seesee", isDirectory: true)
        let originalQueue = try Data(contentsOf: env.dataFile)
        let mover = MediaLibraryMover(
            defaults: env.defaults,
            now: { env.now },
            mountedVolumes: [URL(fileURLWithPath: "/")],
            volumesRoot: fakeVolumes
        )
        let result = mover.move(from: missing, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(result == .failure(MediaFolderCopy.sourceDisconnected), "未连接源必须拒绝，实际 \(result)")
        precondition(try! Data(contentsOf: env.dataFile) == originalQueue)
        precondition(env.preference == nil)
        precondition(!FileManager.default.fileExists(atPath: env.destination.path))
        precondition(!env.journalExists)
    }

    private static func checkMissingSourceFails() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let missing = env.root.appendingPathComponent("no-such-library", isDirectory: true)
        let result = MediaLibraryMover(defaults: env.defaults, now: { env.now })
            .move(from: missing, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        guard case .failure(let reason) = result else {
            fatalError("源目录不存在必须失败，实际 \(result)")
        }
        precondition(reason.contains("源目录不存在"), "失败原因应说明源不存在，实际 \(reason)")
        precondition(env.preference == nil)
        precondition(!FileManager.default.fileExists(atPath: env.destination.path))
    }

    /// 枚举子目录出错必须整次失败，不能只复制看得见的文件。
    private static func checkEnumerationErrorFails() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        try Data("visible-bytes".utf8).write(to: env.source.appendingPathComponent("visible.mp4"))
        let locked = env.source.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("hidden-bytes".utf8).write(to: locked.appendingPathComponent("hidden.mp4"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        let result = MediaLibraryMover(defaults: env.defaults, now: { env.now })
            .move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        guard case .failure(let reason) = result else {
            fatalError("枚举出错必须失败，实际 \(result)")
        }
        precondition(reason.contains("枚举"), "失败原因应提到枚举，实际 \(reason)")
        precondition(env.preference == nil)
        precondition(!FileManager.default.fileExists(atPath: env.destination.path))
    }

    /// copyItem 写出文件后抛错：本次写进去的都清掉，同一目标可以重试。
    private static func checkCopyThrowLeavesNoResidueAndCanRetry() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let originalQueue = try Data(contentsOf: env.dataFile)

        var attempts = 0
        var mover = MediaLibraryMover(defaults: env.defaults, now: { env.now })
        mover.copyItem = { from, to in
            attempts += 1
            try FileManager.default.copyItem(at: from, to: to)
            if attempts == 2 {
                throw NSError(domain: "media-folder-check", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
            }
        }
        let failed = mover.move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        guard case .failure(let reason) = failed else {
            fatalError("复制中途抛错必须失败，实际 \(failed)")
        }
        precondition(reason.contains("disk full"), "失败原因应带上复制器错误，实际 \(reason)")
        assertSourceIntact(library)
        precondition(try! Data(contentsOf: env.dataFile) == originalQueue)
        precondition(env.preference == nil)
        precondition(!FileManager.default.fileExists(atPath: env.destination.path), "已复制的和抛错前落地的都要清掉")
        precondition(!env.journalExists)

        let retry = MediaLibraryMover(defaults: env.defaults, now: { env.now })
            .move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(retry == .success, "清干净后重试同一目标应当成功，实际 \(retry)")
        assertSourceIntact(library)
        for file in library.sourceFiles {
            precondition(FileManager.default.fileExists(atPath: env.destination.appendingPathComponent(file.lastPathComponent).path))
        }
    }

    /// 目标卷未挂载时不得 createDirectory。
    private static func checkDisconnectedDestinationDoesNotCreate() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let fakeVolumes = env.root.appendingPathComponent("Volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeVolumes, withIntermediateDirectories: true)
        let dest = fakeVolumes.appendingPathComponent("不存在的卷/seesee", isDirectory: true)
        let mover = MediaLibraryMover(
            defaults: env.defaults,
            now: { env.now },
            mountedVolumes: [URL(fileURLWithPath: "/")],
            volumesRoot: fakeVolumes
        )
        let result = mover.move(from: env.source, to: dest, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(result == .failure(MediaFolderCopy.destinationDisconnected), "目标未连接必须拒绝，实际 \(result)")
        assertSourceIntact(library)
        precondition(env.preference == nil)
        precondition(!FileManager.default.fileExists(atPath: fakeVolumes.appendingPathComponent("不存在的卷").path))
    }

    /// queue.json 解码失败：准备阶段就拒绝，备份、记录、新位置一样都不写。
    private static func checkCorruptQueueRefusedBeforeAnyWrite() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let corrupt = Data("[{\"id\":".utf8)
        try corrupt.write(to: env.dataFile)
        let result = MediaLibraryMover(defaults: env.defaults, now: { env.now })
            .move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(result == .failure(MediaFolderCopy.queueUnreadable), "实际 \(result)")
        precondition(try! Data(contentsOf: env.dataFile) == corrupt)
        precondition(try! FileManager.default.contentsOfDirectory(atPath: env.support.path) == ["queue.json"])
        precondition(!FileManager.default.fileExists(atPath: env.destination.path))
        precondition(env.preference == nil)
        assertSourceIntact(library)
    }

    // MARK: - 搬移记录与退回

    /// 记录在复制前写好：清单只含本次要写的文件，新位置原本就有的同名同内容文件不在其中。
    private static func checkJournalListsOnlyFilesThisRunWrites() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let existing = library.sourceFiles[0]
        try FileManager.default.createDirectory(at: env.destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: existing, to: env.destination.appendingPathComponent(existing.lastPathComponent))
        let nested = env.source.appendingPathComponent("a/b/deep.txt")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: nested)

        var journalAtFirstCopy: MediaFolderMoveJournal?
        var mover = MediaLibraryMover(defaults: env.defaults, now: { env.now })
        mover.copyItem = { from, to in
            if journalAtFirstCopy == nil {
                journalAtFirstCopy = try MediaFolderMoveJournal.read(beside: env.dataFile)
            }
            try FileManager.default.copyItem(at: from, to: to)
        }
        let result = mover.move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(result == .success)
        guard let journal = journalAtFirstCopy else { fatalError("第一次复制前必须已写好搬移记录") }
        precondition(!journal.copiedFiles.contains(existing.lastPathComponent), "新位置原本就有的文件不进清单")
        precondition(Set(journal.copiedFiles) == Set([library.sourceFiles[1].lastPathComponent, "a/b/deep.txt"]), "实际 \(journal.copiedFiles)")
        precondition(journal.createdDirectories == ["a", "a/b"], "实际 \(journal.createdDirectories)")
        precondition(!journal.createdDestination, "新位置目录原本就在")
        precondition(journal.previousPreference == nil)
        precondition(journal.queueBackup == "queue.json.bak-\(backupStamp(env.now))")
    }

    /// 退回时只删清单里的文件：新位置原本就有的同名同内容文件、原本就有的其他文件都留着。
    private static func checkRollbackKeepsPreexistingDestinationFiles() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let existing = library.sourceFiles[0]
        try FileManager.default.createDirectory(at: env.destination, withIntermediateDirectories: true)
        let preexistingCopy = env.destination.appendingPathComponent(existing.lastPathComponent)
        try FileManager.default.copyItem(at: existing, to: preexistingCopy)
        let unrelated = env.destination.appendingPathComponent("别人的文件.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        let originalQueue = try Data(contentsOf: env.dataFile)

        var mover = MediaLibraryMover(defaults: env.defaults, now: { env.now })
        mover.interruptAfter = .afterPreferenceSaved
        _ = mover.move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(env.journalExists)

        let outcome = MediaFolderMoveRecovery.rollBackPendingMove(
            beside: env.dataFile,
            defaults: env.defaults,
            mountedVolumes: [URL(fileURLWithPath: "/")]
        )
        precondition(outcome == .rolledBack, "实际 \(outcome)")
        precondition(FileManager.default.fileExists(atPath: preexistingCopy.path), "原本就有的同名同内容文件不得删")
        precondition(FileManager.default.fileExists(atPath: unrelated.path), "原本就有的其他文件不得删")
        precondition(!FileManager.default.fileExists(atPath: env.destination.appendingPathComponent(library.sourceFiles[1].lastPathComponent).path))
        precondition(FileManager.default.fileExists(atPath: env.destination.path), "新位置目录原本就在，不删")
        precondition(try! Data(contentsOf: env.dataFile) == originalQueue)
        precondition(env.preference == nil)
        precondition(!env.journalExists)
        assertSourceIntact(library)
    }

    /// 清新位置失败：queue.json 与偏好已退回、记录保留，挡住新的更改；能删之后下一次就退干净。
    /// 退回后应用照常写的 queue.json，重试时不得再被备份覆盖。
    private static func checkRollbackCleanupFailureKeepsJournalAndRetries() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let originalQueue = try Data(contentsOf: env.dataFile)

        var mover = MediaLibraryMover(defaults: env.defaults, now: { env.now })
        mover.interruptAfter = .afterQueueRemapped
        _ = mover.move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)

        let stuck = MediaFolderMoveRecovery.rollBackPendingMove(
            beside: env.dataFile,
            defaults: env.defaults,
            mountedVolumes: [URL(fileURLWithPath: "/")],
            removeItem: { url in
                if url.path.hasPrefix(env.destination.path) {
                    throw NSError(domain: "media-folder-check", code: 5, userInfo: [NSLocalizedDescriptionKey: "read-only volume"])
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        guard case .needsAttention(let reason) = stuck else { fatalError("清不掉必须报出来，实际 \(stuck)") }
        precondition(reason.contains("read-only volume") && reason.contains(env.destination.path), "实际 \(reason)")
        precondition(reason.contains(MediaFolderCopy.pendingMoveRolledBack))
        precondition(try! Data(contentsOf: env.dataFile) == originalQueue, "清不掉新位置也要先把 queue.json 退回")
        precondition(env.preference == nil)
        precondition(env.journalExists, "没退干净必须保留记录")
        precondition(try! MediaFolderMoveJournal.read(beside: env.dataFile)?.queueBackup == nil, "queue.json 退回后记录里不再指向备份")
        assertSourceIntact(library)

        let blocked = MediaLibraryMover(
            removeItem: { _ in throw NSError(domain: "media-folder-check", code: 6, userInfo: [NSLocalizedDescriptionKey: "still read-only"]) },
            defaults: env.defaults
        ).move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        guard case .failure(let blockedReason) = blocked else { fatalError("没退干净时不得开始新的更改，实际 \(blocked)") }
        precondition(blockedReason.contains("still read-only"))

        // 退回后应用改了播放进度并保存。
        var items = try loadItems(env)
        items[0].playbackPosition = 42
        try writeQueue(items, env)
        let edited = try Data(contentsOf: env.dataFile)

        let retried = MediaFolderMoveRecovery.rollBackPendingMove(
            beside: env.dataFile,
            defaults: env.defaults,
            mountedVolumes: [URL(fileURLWithPath: "/")]
        )
        precondition(retried == .rolledBack, "实际 \(retried)")
        precondition(try! Data(contentsOf: env.dataFile) == edited, "重试清理不得拿备份覆盖之后写的 queue.json")
        precondition(!FileManager.default.fileExists(atPath: env.destination.path))
        precondition(!env.journalExists)
    }

    /// 启动时新位置所在的卷没接：先退回 queue.json 和偏好，记录留着，接上后再清。
    private static func checkRollbackWithDestinationDisconnected() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let originalQueue = try Data(contentsOf: env.dataFile)
        let fakeVolumes = env.root.appendingPathComponent("Volumes", isDirectory: true)
        let dest = fakeVolumes.appendingPathComponent("外置盘/seesee", isDirectory: true)
        let mounted = [URL(fileURLWithPath: "/"), fakeVolumes.appendingPathComponent("外置盘")]

        var mover = MediaLibraryMover(defaults: env.defaults, now: { env.now }, mountedVolumes: mounted, volumesRoot: fakeVolumes)
        mover.interruptAfter = .afterPreferenceSaved
        _ = mover.move(from: env.source, to: dest, dataFile: env.dataFile, hasActiveDownload: false)
        let copied = try FileManager.default.contentsOfDirectory(atPath: dest.path).count

        let unplugged = MediaFolderMoveRecovery.rollBackPendingMove(
            beside: env.dataFile,
            defaults: env.defaults,
            mountedVolumes: [URL(fileURLWithPath: "/")],
            volumesRoot: fakeVolumes
        )
        precondition(unplugged == .needsAttention(MediaFolderCopy.pendingDestinationDisconnected(dest.standardizedFileURL.path)), "实际 \(unplugged)")
        precondition(try! Data(contentsOf: env.dataFile) == originalQueue)
        precondition(env.preference == nil)
        precondition(env.journalExists)
        precondition(try! FileManager.default.contentsOfDirectory(atPath: dest.path).count == copied, "没接上时不动新位置")

        let plugged = MediaFolderMoveRecovery.rollBackPendingMove(
            beside: env.dataFile,
            defaults: env.defaults,
            mountedVolumes: mounted,
            volumesRoot: fakeVolumes
        )
        precondition(plugged == .rolledBack, "实际 \(plugged)")
        precondition(!FileManager.default.fileExists(atPath: dest.path))
        precondition(!env.journalExists)
        assertSourceIntact(library)
    }

    /// 记录本身读不出来：无法判断，什么都不动，也不开始新的更改。
    private static func checkUnreadableJournalTouchesNothing() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let garbage = Data("not a journal".utf8)
        try garbage.write(to: env.support.appendingPathComponent(MediaFolderMoveJournal.fileName))
        let originalQueue = try Data(contentsOf: env.dataFile)
        let result = MediaLibraryMover(defaults: env.defaults)
            .move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(result == .failure(MediaFolderCopy.pendingMoveUnreadable), "实际 \(result)")
        precondition(try! Data(contentsOf: env.support.appendingPathComponent(MediaFolderMoveJournal.fileName)) == garbage)
        precondition(try! Data(contentsOf: env.dataFile) == originalQueue)
        precondition(!FileManager.default.fileExists(atPath: env.destination.path))
        assertSourceIntact(library)
    }

    /// 切到新位置后再切回旧位置：旧位置那份还在且内容相同，直接核对切换，两边都不删。
    private static func checkMoveBackToOldLocation() throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let first = MediaLibraryMover(defaults: env.defaults, now: { env.now })
            .move(from: env.source, to: env.destination, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(first == .success)

        var copies = 0
        var mover = MediaLibraryMover(defaults: env.defaults, now: { env.now })
        mover.copyItem = { from, to in
            copies += 1
            try FileManager.default.copyItem(at: from, to: to)
        }
        let back = mover.move(from: env.destination, to: env.source, dataFile: env.dataFile, hasActiveDownload: false)
        precondition(back == .success, "实际 \(back)")
        precondition(copies == 0, "旧位置已有同样的文件，不需要再复制")
        assertSourceIntact(library)
        for file in library.sourceFiles {
            precondition(FileManager.default.fileExists(atPath: env.destination.appendingPathComponent(file.lastPathComponent).path))
        }
        precondition(try! loadItems(env).allSatisfy { $0.localFilePath?.hasPrefix(env.source.path + "/") == true })
        precondition(env.preference == env.source.standardizedFileURL.path)
        precondition(try! env.backupFiles().count == 2, "两次切换各留一份备份，同一秒也不覆盖")
    }

    // MARK: - 环境

    private struct Env {
        let root: URL
        let source: URL
        let destination: URL
        let support: URL
        let dataFile: URL
        let defaults: UserDefaults
        let suite: String
        let now = Date(timeIntervalSince1970: 1_790_226_900)

        var preference: String? { defaults.string(forKey: MediaFolderPreference.key) }

        var journalExists: Bool {
            FileManager.default.fileExists(atPath: MediaFolderMoveJournal.url(beside: dataFile).path)
        }

        func backupFiles() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: support.path).filter { $0.hasPrefix("queue.json.bak-") }
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct SeededLibrary {
        let items: [WatchItem]
        let sourceFiles: [URL]
        let hashes: [String]
    }

    private static func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-mover-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let source = root.appendingPathComponent("from", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let dataFile = support.appendingPathComponent("queue.json")
        try Data("[]".utf8).write(to: dataFile)
        let suite = "media-mover-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Env(
            root: root,
            source: source,
            destination: root.appendingPathComponent("to", isDirectory: true),
            support: support,
            dataFile: dataFile,
            defaults: defaults,
            suite: suite
        )
    }

    private static func seedLibrary(_ env: Env) throws -> SeededLibrary {
        var items: [WatchItem] = []
        var files: [URL] = []
        for index in 0..<2 {
            let id = UUID()
            let video = env.source.appendingPathComponent("\(id.uuidString).mp4")
            try Data("video-bytes-\(index)".utf8).write(to: video)
            files.append(video)
            items.append(sampleItem(id: id, local: video.path, thumbnail: nil, subtitle: nil))
        }
        try writeQueue(items, env)
        return SeededLibrary(items: items, sourceFiles: files, hashes: files.map(shasum))
    }

    private static func assertSourceIntact(_ library: SeededLibrary) {
        for (file, hash) in zip(library.sourceFiles, library.hashes) {
            precondition(FileManager.default.fileExists(atPath: file.path), "旧位置的 \(file.lastPathComponent) 必须还在")
            precondition(shasum(file) == hash, "旧位置的 \(file.lastPathComponent) 内容不得变")
        }
    }

    private static func writeQueue(_ items: [WatchItem], _ env: Env) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: env.dataFile)
    }

    private static func loadItems(_ env: Env) throws -> [WatchItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([WatchItem].self, from: Data(contentsOf: env.dataFile))
    }

    private static func sampleItem(id: UUID, local: String?, thumbnail: String?, subtitle: String?) -> WatchItem {
        WatchItem(
            id: id,
            urlString: "https://example.com/\(id.uuidString)",
            title: "sample",
            author: "check",
            duration: 12,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            watchedAt: nil,
            state: .ready,
            progress: 1,
            progressLabel: "已下载",
            localFilePath: local,
            errorMessage: nil,
            playbackPosition: nil,
            chapters: nil,
            thumbnailFilePath: thumbnail,
            subtitleFilePath: subtitle
        )
    }

    private static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func shasum(_ url: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            fatalError("无法运行 shasum：\(error)")
        }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let hash = String(output.prefix(64))
        precondition(hash.count == 64, "shasum 输出异常：\(output)")
        return hash
    }
}
