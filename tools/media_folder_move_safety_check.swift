import CryptoKit
import Foundation

/// 更改片库位置的数据安全检查，全部经真实 `QueueStore` 装配：
/// 搬移用 `store.moveMediaFolder`，「下次启动」用同一数据文件重新构造 `QueueStore`。
/// 中断用生产代码里的 `MediaLibraryMover.interruptAfter` 钩子：到点直接抛出、不走失败清理，
/// 现场与进程在那一刻退出相同。每条单独记结果，最后汇总，便于看清哪几条红。
@main
struct MediaFolderMoveSafetyCheck {
    static func main() async throws {
        await run("switch_keeps_every_old_file", checkSwitchKeepsEveryOldFile)
        await run("interrupt_during_copy", checkInterruptDuringCopy)
        await run("interrupt_at_verify_failure", checkInterruptAtVerifyFailure)
        await run("verify_failure_in_process", checkVerifyFailureInProcess)
        await run("interrupt_during_queue_rewrite", checkInterruptDuringQueueRewrite)
        await run("interrupt_after_preference_saved", checkInterruptAfterPreferenceSaved)
        await run("corrupt_queue_move_touches_nothing", checkCorruptQueueMoveTouchesNothing)
        await run("corrupt_queue_pending_move_touches_nothing", checkCorruptQueuePendingMoveTouchesNothing)
        await run("queue_corrupted_while_running_move_touches_nothing", checkQueueCorruptedWhileRunningMoveTouchesNothing)

        let failed = results.filter { !$0.failures.isEmpty }
        for result in results {
            if result.failures.isEmpty {
                print("PASS \(result.name)")
            } else {
                print("FAIL \(result.name)")
                for failure in result.failures {
                    print("  - \(failure)")
                }
            }
        }
        if failed.isEmpty {
            print("media_folder_move_safety_check=passed")
        } else {
            print("media_folder_move_safety_check=failed \(failed.count)/\(results.count)")
            exit(1)
        }
    }

    // MARK: - 用例

    /// 切换成功后，旧位置的每个文件都还在，内容逐个 SHA-256 不变。
    private static func checkSwitchKeepsEveryOldFile() async throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        let library = try seedLibrary(env)
        let before = try snapshot(env.source)

        let result = await MainActor.run { () -> MediaLibraryMoveResult in
            let store = QueueStore(dataFile: env.dataFile, mediaFolder: env.source, defaults: env.defaults)
            return store.moveMediaFolder(to: env.destination)
        }
        expect(result == .success, "切换应当成功，实际 \(result)")

        let after = try snapshot(env.source)
        expect(after == before, "旧位置文件必须一个不少、内容不变：少了 \(missing(before, after))，变了 \(changed(before, after))")
        let copied = try snapshot(env.destination)
        expect(copied == before, "新位置必须是旧位置的完整副本：少了 \(missing(before, copied))，变了 \(changed(before, copied))")

        let items = try decodeQueue(env.dataFile)
        for item in items {
            for path in [item.localFilePath, item.thumbnailFilePath, item.subtitleFilePath] {
                expect(path?.hasPrefix(env.destination.standardizedFileURL.path + "/") == true, "队列三类路径都应指向新位置：\(path ?? "nil")")
            }
        }
        expect(items.count == library.items.count, "队列条目数不能变")
        expect(env.preference == env.destination.standardizedFileURL.path, "偏好应指向新位置")
        expect(!env.journalExists, "切换完成后不留搬移记录")
        expect(try env.backupFiles().count == 1, "应留下一份 queue.json 备份")
    }

    /// 中断点 1：复制到一半进程退出。下次启动清掉新位置里本次复制的文件，按旧位置运行。
    private static func checkInterruptDuringCopy() async throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        _ = try seedLibrary(env)
        var mover = MediaLibraryMover(defaults: env.defaults)
        mover.interruptAfter = .afterCopyProgress(completed: 2)
        try await interruptThenRelaunch(env, mover: mover) {
            let partial = (try? snapshot(env.destination).count) ?? 0
            expect(partial == 2, "钩子应停在复制完第 2 个文件，实际新位置有 \(partial) 个")
        }
    }

    /// 中断点 2：核对发现不一致的那一刻进程退出（失败清理没来得及跑）。
    private static func checkInterruptAtVerifyFailure() async throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        _ = try seedLibrary(env)
        var mover = MediaLibraryMover(defaults: env.defaults)
        mover.copyItem = corruptingSecondCopy()
        mover.interruptAfter = .atVerifyFailure
        try await interruptThenRelaunch(env, mover: mover) {
            let partial = (try? snapshot(env.destination).count) ?? 0
            expect(partial > 0, "核对失败时新位置应已有复制出的文件，现场才有意义")
        }
    }

    /// 核对失败、进程没退出：当场清掉本次复制的文件，旧位置和 queue.json 原样。
    private static func checkVerifyFailureInProcess() async throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        _ = try seedLibrary(env)
        let before = try snapshot(env.source)
        let queueBefore = try Data(contentsOf: env.dataFile)
        var mover = MediaLibraryMover(defaults: env.defaults)
        mover.copyItem = corruptingSecondCopy()

        let configured = mover
        let result = await MainActor.run { () -> MediaLibraryMoveResult in
            let store = QueueStore(dataFile: env.dataFile, mediaFolder: env.source, defaults: env.defaults)
            return store.moveMediaFolder(to: env.destination, mover: configured)
        }
        guard case .failure = result else {
            expect(false, "复制后内容被改坏必须失败，实际 \(result)")
            return
        }
        expect(try snapshot(env.source) == before, "旧位置文件必须原样")
        expect(try Data(contentsOf: env.dataFile) == queueBefore, "queue.json 必须原样")
        expect(env.preference == nil, "偏好不得改")
        expect(!FileManager.default.fileExists(atPath: env.destination.path), "新位置不得留下复制的文件")
        expect(!env.journalExists, "当场清干净后不留搬移记录")
    }

    /// 中断点 3：queue.json 已改写成新路径、偏好还没写时进程退出。
    private static func checkInterruptDuringQueueRewrite() async throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        _ = try seedLibrary(env)
        var mover = MediaLibraryMover(defaults: env.defaults)
        mover.interruptAfter = .afterQueueRemapped
        try await interruptThenRelaunch(env, mover: mover) {
            let items = (try? decodeQueue(env.dataFile)) ?? []
            let rewritten = items.contains { $0.localFilePath?.hasPrefix(env.destination.standardizedFileURL.path) == true }
            expect(rewritten, "钩子应停在 queue.json 已改写之后")
        }
    }

    /// 切换的最后一步（删搬移记录）之前退出：偏好已写，也按未完成处理，回到旧位置。
    private static func checkInterruptAfterPreferenceSaved() async throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        _ = try seedLibrary(env)
        var mover = MediaLibraryMover(defaults: env.defaults)
        mover.interruptAfter = .afterPreferenceSaved
        try await interruptThenRelaunch(env, mover: mover) {
            expect(env.preference == env.destination.standardizedFileURL.path, "钩子应停在偏好已写之后")
        }
    }

    /// queue.json 解码失败时要求更改位置：不写、不删、不复制，任何文件都不动。
    private static func checkCorruptQueueMoveTouchesNothing() async throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        _ = try seedLibrary(env)
        let corrupt = Data("{ 这不是队列".utf8)
        try corrupt.write(to: env.dataFile)
        let before = try snapshot(env.source)
        let supportBefore = try snapshot(env.support)

        let result = await MainActor.run { () -> MediaLibraryMoveResult in
            let store = QueueStore(dataFile: env.dataFile, mediaFolder: env.source, defaults: env.defaults)
            let result = store.moveMediaFolder(to: env.destination)
            store.flushPendingSaves()
            return result
        }
        guard case .failure = result else {
            expect(false, "queue.json 读不出来时必须拒绝，实际 \(result)")
            return
        }
        expect(try snapshot(env.source) == before, "旧位置文件不得有任何变化")
        expect(try Data(contentsOf: env.dataFile) == corrupt, "损坏的 queue.json 不得被覆盖")
        expect(try snapshot(env.support) == supportBefore, "数据目录不得多出或改动任何文件（备份、记录都不写）")
        expect(!FileManager.default.fileExists(atPath: env.destination.path), "不得创建新位置")
        expect(env.preference == nil, "偏好不得改")
    }

    /// 应用启动时 queue.json 还好好的，运行中途被改坏，这时用户点「更改…」：
    /// 不得先把内存里的旧队列写回去再搬，必须按当前磁盘上的文件判断，任何文件都不动。
    private static func checkQueueCorruptedWhileRunningMoveTouchesNothing() async throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        _ = try seedLibrary(env)
        let store = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: env.source, defaults: env.defaults)
        }
        let loaded = await MainActor.run { store.items.count }
        expect(loaded == 3, "启动时队列应能正常读出 3 条，实际 \(loaded)")

        let corrupt = Data("{ 运行中被改坏".utf8)
        try corrupt.write(to: env.dataFile)
        let before = try snapshot(env.source)
        let supportBefore = try snapshot(env.support)

        let observed = await MainActor.run { () -> (MediaLibraryMoveResult, String?, String) in
            let result = store.moveMediaFolder(to: env.destination)
            store.flushPendingSaves()
            return (result, store.mediaFolderMoveMessage, store.mediaFolder.standardizedFileURL.path)
        }
        expect(observed.0 == .failure(MediaFolderCopy.queueUnreadable), "运行中 queue.json 坏了必须拒绝，实际 \(observed.0)")
        expect(
            observed.1 == MediaFolderCopy.failure(MediaFolderCopy.queueUnreadable),
            "设置页应提示 queue.json 读不出来，实际 \(String(describing: observed.1))"
        )
        expect(observed.2 == env.source.standardizedFileURL.path, "片库位置不得切换")
        expect(try Data(contentsOf: env.dataFile) == corrupt, "坏掉的 queue.json 不得被内存里的旧队列覆盖")
        expect(try snapshot(env.support) == supportBefore, "数据目录不得多出或改动任何文件（备份、记录都不写）")
        expect(try snapshot(env.source) == before, "旧位置文件不得有任何变化")
        expect(!FileManager.default.fileExists(atPath: env.destination.path), "不得创建新位置")
        expect(env.preference == nil, "偏好不得改")
    }

    /// 有未完成的搬移、同时 queue.json 解码失败：恢复逻辑无法判断，任何文件都不动。
    private static func checkCorruptQueuePendingMoveTouchesNothing() async throws {
        let env = try makeEnv()
        defer { env.cleanUp() }
        _ = try seedLibrary(env)
        var mover = MediaLibraryMover(defaults: env.defaults)
        mover.interruptAfter = .afterPreferenceSaved
        let configured = mover
        _ = await MainActor.run { () -> MediaLibraryMoveResult in
            let store = QueueStore(dataFile: env.dataFile, mediaFolder: env.source, defaults: env.defaults)
            return store.moveMediaFolder(to: env.destination, mover: configured)
        }
        expect(env.journalExists, "中断后应留下搬移记录")

        let corrupt = Data("{ 这不是队列".utf8)
        try corrupt.write(to: env.dataFile)
        let sourceBefore = try snapshot(env.source)
        let destinationBefore = try snapshot(env.destination)
        let supportBefore = try snapshot(env.support)
        let preferenceBefore = env.preference

        await MainActor.run {
            let store = QueueStore(dataFile: env.dataFile, mediaFolder: env.source, defaults: env.defaults)
            store.flushPendingSaves()
        }
        expect(try snapshot(env.source) == sourceBefore, "旧位置文件不得有任何变化")
        expect(try snapshot(env.destination) == destinationBefore, "无法判断时新位置也不删")
        expect(try Data(contentsOf: env.dataFile) == corrupt, "损坏的 queue.json 不得被覆盖")
        expect(try snapshot(env.support) == supportBefore, "数据目录不得有任何变化，搬移记录保留")
        expect(env.preference == preferenceBefore, "偏好不得改")
    }

    // MARK: - 共用步骤

    /// 用钩子中断一次搬移，再以同一数据文件「重新启动」，核对回到旧位置且新位置没有残留。
    private static func interruptThenRelaunch(
        _ env: Env,
        mover: MediaLibraryMover,
        atInterrupt: () -> Void
    ) async throws {
        let before = try snapshot(env.source)
        let queueBefore = try Data(contentsOf: env.dataFile)

        let result = await MainActor.run { () -> MediaLibraryMoveResult in
            let store = QueueStore(dataFile: env.dataFile, mediaFolder: env.source, defaults: env.defaults)
            return store.moveMediaFolder(to: env.destination, mover: mover)
        }
        guard case .failure = result else {
            expect(false, "中断的搬移不能报成功，实际 \(result)")
            return
        }
        expect(env.journalExists, "中断后应留下搬移记录，现场与进程退出一致")
        atInterrupt()

        let relaunchedPaths = await MainActor.run { () -> [String?] in
            let store = QueueStore(dataFile: env.dataFile, mediaFolder: env.source, defaults: env.defaults)
            return store.items.map(\.localFilePath)
        }
        expect(try snapshot(env.source) == before, "旧位置文件必须一个不少、内容不变")
        expect(try Data(contentsOf: env.dataFile) == queueBefore, "queue.json 必须回到搬移前的内容")
        expect(env.preference == nil, "偏好必须回到搬移前（未设置）")
        expect(!env.journalExists, "恢复完成后不留搬移记录")
        let leftover = (try? snapshot(env.destination)) ?? [:]
        expect(leftover.isEmpty, "新位置里本次复制的文件必须清掉，还剩 \(leftover.keys.sorted())")
        expect(!FileManager.default.fileExists(atPath: env.destination.path), "本次新建的新位置目录应一并清掉")
        for path in relaunchedPaths {
            expect(path?.hasPrefix(env.source.standardizedFileURL.path + "/") == true, "重启后队列应指向旧位置：\(path ?? "nil")")
        }
    }

    private static func corruptingSecondCopy() -> (URL, URL) throws -> Void {
        var calls = 0
        return { from, to in
            calls += 1
            try FileManager.default.copyItem(at: from, to: to)
            if calls == 2 {
                try Data("copy-went-wrong".utf8).write(to: to)
            }
        }
    }

    // MARK: - 结果记录

    private struct CaseResult {
        let name: String
        var failures: [String]
    }

    nonisolated(unsafe) private static var results: [CaseResult] = []
    nonisolated(unsafe) private static var current: [String] = []

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String) {
        do {
            if try !condition() { current.append(message()) }
        } catch {
            current.append("\(message())（检查时出错：\(error)）")
        }
    }

    private static func run(_ name: String, _ body: () async throws -> Void) async {
        current = []
        do {
            try await body()
        } catch {
            current.append("抛出错误：\(error)")
        }
        results.append(CaseResult(name: name, failures: current))
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

        var preference: String? { defaults.string(forKey: MediaFolderPreference.key) }

        var journalExists: Bool {
            FileManager.default.fileExists(atPath: support.appendingPathComponent("media-folder-move.inprogress").path)
        }

        func backupFiles() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: support.path).filter { $0.hasPrefix("queue.json.bak-") }
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct Library {
        let items: [WatchItem]
    }

    private static func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-safety-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("library", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let suite = "media-safety-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Env(
            root: root.standardizedFileURL,
            source: source.standardizedFileURL,
            destination: root.appendingPathComponent("new-library", isDirectory: true).standardizedFileURL,
            support: support.standardizedFileURL,
            dataFile: support.appendingPathComponent("queue.json").standardizedFileURL,
            defaults: defaults,
            suite: suite
        )
    }

    /// 三个视频，各带视频、缩略图、字幕三类路径，另有一个队列外的子目录文件。
    private static func seedLibrary(_ env: Env) throws -> Library {
        var items: [WatchItem] = []
        for index in 1...3 {
            let id = UUID()
            let video = env.source.appendingPathComponent("\(id.uuidString).mp4")
            let thumb = env.source.appendingPathComponent("\(id.uuidString).jpg")
            let subtitle = env.source.appendingPathComponent("\(id.uuidString).zh.srt")
            try Data("video-\(index)-bytes".utf8).write(to: video)
            try Data("thumb-\(index)-bytes".utf8).write(to: thumb)
            try Data("subtitle-\(index)-line".utf8).write(to: subtitle)
            items.append(
                WatchItem(
                    id: id,
                    urlString: "https://example.com/\(index)",
                    title: "视频\(index)",
                    author: "check",
                    duration: 10,
                    addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    watchedAt: nil,
                    state: .ready,
                    progress: 1,
                    progressLabel: "已下载",
                    localFilePath: video.path,
                    errorMessage: nil,
                    playbackPosition: Double(index),
                    chapters: nil,
                    thumbnailFilePath: thumb.path,
                    subtitleFilePath: subtitle.path
                )
            )
        }
        let nested = env.source.appendingPathComponent("notes/readme.txt")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nested-note".utf8).write(to: nested)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: env.dataFile)
        return Library(items: items)
    }

    private static func decodeQueue(_ dataFile: URL) throws -> [WatchItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([WatchItem].self, from: Data(contentsOf: dataFile))
    }

    /// 目录下每个普通文件的相对路径到 SHA-256；目录不存在时为空。
    private static func snapshot(_ root: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        let prefix = root.standardizedFileURL.path + "/"
        var result: [String: String] = [:]
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : file.lastPathComponent
            let digest = SHA256.hash(data: try Data(contentsOf: file))
            result[relative] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private static func missing(_ before: [String: String], _ after: [String: String]) -> [String] {
        before.keys.filter { after[$0] == nil }.sorted()
    }

    private static func changed(_ before: [String: String], _ after: [String: String]) -> [String] {
        before.keys.filter { after[$0] != nil && after[$0] != before[$0] }.sorted()
    }
}
