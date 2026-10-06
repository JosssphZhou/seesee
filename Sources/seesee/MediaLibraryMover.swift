import CryptoKit
import Foundation
import os.log

enum MediaFolderLog {
    static let log = OSLog(subsystem: "ai.openmy.seesee", category: "media-folder")

    static func info(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
    }

    static func error(_ message: String) {
        os_log("%{public}@", log: log, type: .error, message)
    }
}

enum MediaLibraryMoveResult: Equatable {
    case success
    case noOp
    case failure(String)
}

/// 生产代码里的中断钩子：到了这一步直接抛出，不走失败清理，留下与进程在此刻退出相同的现场。
enum MediaLibraryMoveInterrupt: Equatable {
    case afterCopyProgress(completed: Int)
    case atVerifyFailure
    case afterQueueRemapped
    case afterPreferenceSaved
}

/// 搬移记录：复制开始前写在 queue.json 旁边，切换的最后一步才删除。
/// 它还在就说明上次搬移没有做完；恢复时按它把一切退回旧位置。
struct MediaFolderMoveJournal: Codable, Equatable {
    static let fileName = "media-folder-move.inprogress"

    var source: String
    var destination: String
    var createdDestination: Bool
    /// 复制前记下的清单：本次要写进新位置的文件（相对路径），新位置原本已有的同名同内容文件不在其中。
    var copiedFiles: [String]
    /// 本次在新位置里新建的子目录（相对路径）。
    var createdDirectories: [String]
    /// 切换前 queue.json 的备份文件名，与 queue.json 同目录。
    /// 恢复时已经把 queue.json 退回旧内容后置空，之后应用照常写队列，重试清理时不再拿备份覆盖。
    var queueBackup: String?
    var previousPreference: String?

    static func url(beside dataFile: URL) -> URL {
        dataFile.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// 没有记录时返回 nil；有记录但读不出来时抛错。
    static func read(beside dataFile: URL) throws -> MediaFolderMoveJournal? {
        let url = url(beside: dataFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(MediaFolderMoveJournal.self, from: Data(contentsOf: url))
    }

    func write(beside dataFile: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(beside: dataFile), options: .atomic)
    }
}

enum MediaFolderMoveRecoveryOutcome: Equatable {
    case nothingPending
    case rolledBack
    /// 没能退干净，记录保留，下次启动或下次更改位置时再试；附给用户看的原因。
    case needsAttention(String)
}

/// 搬移没做完时退回旧位置。启动时和搬移当场失败时走的都是这一段。
/// 旧位置的文件从头到尾不碰；只删复制前清单里、本次写进新位置的文件。
enum MediaFolderMoveRecovery {
    static func rollBackPendingMove(
        beside dataFile: URL,
        defaults: UserDefaults,
        mountedVolumes: [URL],
        volumesRoot: URL = MediaFolderAvailability.defaultVolumesRoot,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> MediaFolderMoveRecoveryOutcome {
        let fileManager = FileManager.default
        let journal: MediaFolderMoveJournal
        do {
            guard let found = try MediaFolderMoveJournal.read(beside: dataFile) else { return .nothingPending }
            journal = found
        } catch {
            return .needsAttention(MediaFolderCopy.pendingMoveUnreadable)
        }

        // queue.json 读不出来或解码失败：无法判断，什么都不写、不删。
        guard let queueData = try? Data(contentsOf: dataFile), decodeQueue(queueData) != nil else {
            return .needsAttention(MediaFolderCopy.queueUnreadable)
        }
        // 备份只在改写 queue.json 之前写成，所以备份在、内容又不同，说明 queue.json 已被改写，退回备份。
        if let backupName = journal.queueBackup {
            let backup = dataFile.deletingLastPathComponent().appendingPathComponent(backupName)
            if fileManager.fileExists(atPath: backup.path) {
                guard let backupData = try? Data(contentsOf: backup), decodeQueue(backupData) != nil else {
                    return .needsAttention(MediaFolderCopy.queueUnreadable)
                }
                if backupData != queueData {
                    do {
                        try backupData.write(to: dataFile, options: .atomic)
                    } catch {
                        return .needsAttention(MediaFolderCopy.pendingMoveNotRestored(error.localizedDescription))
                    }
                }
            }
        }

        let source = URL(fileURLWithPath: journal.source, isDirectory: true).standardizedFileURL
        let destination = URL(fileURLWithPath: journal.destination, isDirectory: true).standardizedFileURL
        if MediaFolderPreference.resolve(defaults: defaults)?.standardizedFileURL.path == destination.path {
            if let previous = journal.previousPreference {
                defaults.set(previous, forKey: MediaFolderPreference.key)
            } else {
                defaults.removeObject(forKey: MediaFolderPreference.key)
            }
        }
        if journal.queueBackup != nil {
            var restored = journal
            restored.queueBackup = nil
            do {
                try restored.write(beside: dataFile)
            } catch {
                return .needsAttention(MediaFolderCopy.pendingMoveNotRestored(error.localizedDescription))
            }
        }

        // 到这里 queue.json 和偏好都已回到旧位置，应用可以照常用旧片库；下面只清新位置。
        guard !MediaFolderPaths.overlap(source, destination) else {
            return .needsAttention(MediaFolderCopy.pendingMoveUnreadable)
        }
        if MediaFolderAvailability.isDisconnected(destination, mountedVolumes: mountedVolumes, volumesRoot: volumesRoot) {
            return .needsAttention(MediaFolderCopy.pendingDestinationDisconnected(destination.path))
        }
        var failures: [String] = []
        for relative in journal.copiedFiles {
            guard let file = MediaFolderPaths.child(relative, of: destination) else { continue }
            guard fileManager.fileExists(atPath: file.path) else { continue }
            do {
                try removeItem(file)
            } catch {
                failures.append("\(relative)：\(error.localizedDescription)")
            }
        }
        // 目录只删本次新建且已经空了的，里面有任何东西就留着。
        let directories = journal.createdDirectories
            .compactMap { MediaFolderPaths.child($0, of: destination) }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for directory in directories where isEmptyDirectory(directory) {
            try? removeItem(directory)
        }
        if journal.createdDestination, isEmptyDirectory(destination) {
            try? removeItem(destination)
        }
        guard failures.isEmpty else {
            return .needsAttention(
                MediaFolderCopy.pendingCleanupFailed(path: destination.path, reason: failures.joined(separator: "；"))
            )
        }
        do {
            try removeItem(MediaFolderMoveJournal.url(beside: dataFile))
        } catch {
            return .needsAttention(MediaFolderCopy.pendingMoveNotRestored(error.localizedDescription))
        }
        return .rolledBack
    }

    static func decodeQueue(_ data: Data) -> [WatchItem]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([WatchItem].self, from: data)
    }

    private static func isEmptyDirectory(_ url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return contents.isEmpty
    }
}

enum MediaFolderPaths {
    static func relativePath(of file: URL, to root: URL) -> String {
        let prefix = directoryPrefix(root)
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(prefix) else { return file.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }

    /// 两个目录相同，或一个在另一个里面。
    static func overlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.path
        let right = rhs.standardizedFileURL.path
        return left == right || left.hasPrefix(directoryPrefix(rhs)) || right.hasPrefix(directoryPrefix(lhs))
    }

    /// 把记录里的相对路径接回根目录；空的、绝对的或带 `..` 的一律不认。
    static func child(_ relative: String, of root: URL) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return root.appendingPathComponent(relative)
    }

    private static func directoryPrefix(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
    }
}

/// 更改片库位置：复制到新位置 → 逐文件核对大小与 SHA-256 → 改写 queue.json 与偏好，切换过去。
/// 旧位置的文件一个都不删；切换完成后旧位置还留着一份，删不删由用户自己决定。
struct MediaLibraryMover {
    var fileManager: FileManager = .default
    var copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    var removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    var defaults: UserDefaults = .standard
    var now: () -> Date = Date.init
    var mountedVolumes: [URL] = MediaFolderAvailability.liveMountedVolumes()
    var volumesRoot: URL = MediaFolderAvailability.defaultVolumesRoot
    var interruptAfter: MediaLibraryMoveInterrupt?

    func move(
        from source: URL,
        to destination: URL,
        dataFile: URL,
        hasActiveDownload: Bool,
        onProgress: ((MediaLibraryMoveProgress) -> Void)? = nil
    ) -> MediaLibraryMoveResult {
        if hasActiveDownload {
            return .failure(MediaFolderCopy.downloadingBlock)
        }
        if case .needsAttention(let reason) = rollBack(dataFile: dataFile) {
            return .failure(reason)
        }
        let from = source.standardizedFileURL
        let to = destination.standardizedFileURL
        if from.path == to.path {
            return .noOp
        }
        if MediaFolderAvailability.isDisconnected(from, mountedVolumes: mountedVolumes, volumesRoot: volumesRoot) {
            return .failure(MediaFolderCopy.sourceDisconnected)
        }
        if MediaFolderAvailability.isDisconnected(to, mountedVolumes: mountedVolumes, volumesRoot: volumesRoot) {
            return .failure(MediaFolderCopy.destinationDisconnected)
        }
        if MediaFolderPaths.overlap(from, to) {
            return .failure(MediaFolderCopy.destinationOverlapsLibrary)
        }

        // 准备阶段只读不写：任何一项不满足就原样返回。
        let plan: MovePlan
        do {
            plan = try makePlan(from: from, to: to, dataFile: dataFile)
        } catch {
            return .failure(error.localizedDescription)
        }

        do {
            try execute(plan, dataFile: dataFile, onProgress: onProgress)
            return .success
        } catch is MediaLibraryMoveInterrupted {
            return .failure(MediaFolderCopy.interrupted)
        } catch {
            let reason = error.localizedDescription
            if case .needsAttention(let note) = rollBack(dataFile: dataFile) {
                return .failure("\(reason)；\(note)")
            }
            return .failure(reason)
        }
    }

    private func rollBack(dataFile: URL) -> MediaFolderMoveRecoveryOutcome {
        MediaFolderMoveRecovery.rollBackPendingMove(
            beside: dataFile,
            defaults: defaults,
            mountedVolumes: mountedVolumes,
            volumesRoot: volumesRoot,
            removeItem: removeItem
        )
    }

    private struct MovePlan {
        var source: URL
        var destination: URL
        var files: [URL]
        var queueData: Data
        var items: [WatchItem]
        var backupName: String
        var journal: MediaFolderMoveJournal
    }

    private func makePlan(from source: URL, to destination: URL, dataFile: URL) throws -> MovePlan {
        guard let queueData = try? Data(contentsOf: dataFile),
              let items = MediaFolderMoveRecovery.decodeQueue(queueData) else {
            throw MediaLibraryMoveFailure(MediaFolderCopy.queueUnreadable)
        }
        let files = try listFiles(in: source)
        var copiedFiles: [String] = []
        var createdDirectories: Set<String> = []
        for file in files {
            let relative = MediaFolderPaths.relativePath(of: file, to: source)
            let destFile = destination.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: destFile.path) {
                guard try sameContent(file, destFile) else {
                    throw MediaLibraryMoveFailure("目标目录已有同名文件，内容不同，没有覆盖：\(destFile.lastPathComponent)")
                }
                continue
            }
            copiedFiles.append(relative)
            var parent = (relative as NSString).deletingLastPathComponent
            while !parent.isEmpty, !fileManager.fileExists(atPath: destination.appendingPathComponent(parent).path) {
                createdDirectories.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let backupName = unusedBackupName(beside: dataFile)
        let journal = MediaFolderMoveJournal(
            source: source.path,
            destination: destination.path,
            createdDestination: !fileManager.fileExists(atPath: destination.path),
            copiedFiles: copiedFiles,
            createdDirectories: createdDirectories.sorted(),
            queueBackup: backupName,
            previousPreference: defaults.string(forKey: MediaFolderPreference.key)
        )
        return MovePlan(
            source: source,
            destination: destination,
            files: files,
            queueData: queueData,
            items: items,
            backupName: backupName,
            journal: journal
        )
    }

    private func execute(
        _ plan: MovePlan,
        dataFile: URL,
        onProgress: ((MediaLibraryMoveProgress) -> Void)?
    ) throws {
        try plan.journal.write(beside: dataFile)

        // 复制：只写清单里的文件，新位置原本已有的同名同内容文件不动。
        try fileManager.createDirectory(at: plan.destination, withIntermediateDirectories: true)
        let pending = Set(plan.journal.copiedFiles)
        let total = plan.files.count
        for (index, file) in plan.files.enumerated() {
            let relative = MediaFolderPaths.relativePath(of: file, to: plan.source)
            if pending.contains(relative) {
                let destFile = plan.destination.appendingPathComponent(relative)
                try fileManager.createDirectory(
                    at: destFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try copyItem(file, destFile)
            }
            onProgress?(MediaLibraryMoveProgress(completed: index + 1, total: total))
            try interruptIfNeeded(.afterCopyProgress(completed: index + 1))
        }

        // 核对：每个文件大小一致且 SHA-256 一致。
        for file in plan.files {
            let destFile = plan.destination.appendingPathComponent(MediaFolderPaths.relativePath(of: file, to: plan.source))
            let matched = fileManager.fileExists(atPath: destFile.path) ? try sameContent(file, destFile) : false
            if !matched {
                try interruptIfNeeded(.atVerifyFailure)
                throw MediaLibraryMoveFailure("核对失败，\(file.lastPathComponent) 复制后内容不一致")
            }
        }

        // 切换：先备份 queue.json，再改写路径，再写偏好，最后删掉搬移记录。
        let backup = dataFile.deletingLastPathComponent().appendingPathComponent(plan.backupName)
        try plan.queueData.write(to: backup, options: .atomic)
        try writeRemappedQueue(plan.items, from: plan.source, to: plan.destination, dataFile: dataFile)
        try interruptIfNeeded(.afterQueueRemapped)
        MediaFolderPreference.save(plan.destination, defaults: defaults)
        try interruptIfNeeded(.afterPreferenceSaved)
        try removeItem(MediaFolderMoveJournal.url(beside: dataFile))
    }

    private func sameContent(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let leftSize = try fileSize(lhs)
        let rightSize = try fileSize(rhs)
        guard leftSize == rightSize else { return false }
        return try sha256(lhs) == sha256(rhs)
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw MediaLibraryMoveFailure("读不到文件大小：\(url.lastPathComponent)")
        }
        return size.uint64Value
    }

    private func sha256(_ url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func listFiles(in root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw MediaLibraryMoveFailure("源目录不存在，无法搬移")
        }
        guard isDirectory.boolValue else {
            throw MediaLibraryMoveFailure("源路径不是目录，无法搬移")
        }
        guard fileManager.isReadableFile(atPath: root.path) else {
            throw MediaLibraryMoveFailure("枚举源目录失败：没有读取权限")
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw MediaLibraryMoveFailure("无法枚举源目录")
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            if let enumerationError {
                throw MediaLibraryMoveFailure("枚举源目录失败：\(enumerationError.localizedDescription)")
            }
            if file.lastPathComponent == ".DS_Store" { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true { continue }
            if values.isRegularFile == true {
                files.append(file.standardizedFileURL)
            }
        }
        if let enumerationError {
            throw MediaLibraryMoveFailure("枚举源目录失败：\(enumerationError.localizedDescription)")
        }
        return files
    }

    private func unusedBackupName(beside dataFile: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "queue.json.bak-\(formatter.string(from: now()))"
        let folder = dataFile.deletingLastPathComponent()
        var name = base
        var suffix = 1
        while fileManager.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        return name
    }

    private func writeRemappedQueue(
        _ items: [WatchItem],
        from source: URL,
        to destination: URL,
        dataFile: URL
    ) throws {
        let remap = MediaPathRemap(
            mediaFolder: destination,
            movedFromMediaFolder: source
        )
        var remapped = items
        for index in remapped.indices {
            remapped[index].localFilePath = remap.remappedMediaPath(remapped[index].localFilePath)
            remapped[index].thumbnailFilePath = remap.remappedMediaPath(remapped[index].thumbnailFilePath)
            remapped[index].subtitleFilePath = remap.remappedMediaPath(remapped[index].subtitleFilePath)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(remapped).write(to: dataFile, options: .atomic)
    }

    private func interruptIfNeeded(_ step: MediaLibraryMoveInterrupt) throws {
        guard interruptAfter == step else { return }
        throw MediaLibraryMoveInterrupted()
    }
}

private struct MediaLibraryMoveInterrupted: Error {}

private struct MediaLibraryMoveFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
