import Foundation

/// 边下边播的重试：下载中途失败、自动重试时，正在播的预览不断，也不换地址，下完才换成本地文件。
/// 播放器报告预览不可用、预览被清掉以后，重试时解析出的新预览要用上。
/// 从真实的 `QueueStore()` 启动：队列从临时家目录的 queue.json 读出，启动时自动开始下载，
/// 下载失败后走生产代码自己的重试。只用重试改动之前就有的接口，旧代码上也能编译运行，并在第一条断言失败。
/// 只能经 scripts/test_progressive_retry.sh 运行：它造一个临时应用、临时家目录和假的 yt-dlp。

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

/// 播放器和队列这一行能看到的状态，只在变化时记一条。
private struct Snapshot: Equatable {
    let state: DownloadState
    let label: String
    let source: PlayerReadyDecision.Source
    let previewPlayable: Bool

    var text: String {
        let stateName: String
        switch state {
        case .queued: stateName = "排队"
        case .downloading: stateName = "下载中"
        case .ready: stateName = "已下完"
        case .failed: stateName = "失败"
        }
        let played: String
        switch source {
        case .preview(let url): played = "播预览 \(url.lastPathComponent)"
        case .localFile(let url): played = "播本地文件 \(url.lastPathComponent)"
        case .none: played = "没有可播的片源"
        }
        return "\(stateName)「\(label)」，\(played)"
    }
}

private struct Timeline {
    var entries: [(seconds: Double, snapshot: Snapshot)] = []

    mutating func record(_ snapshot: Snapshot?, at seconds: Double) {
        guard let snapshot, entries.last?.snapshot != snapshot else { return }
        entries.append((seconds, snapshot))
    }

    var last: Snapshot? { entries.last?.snapshot }

    func describe() -> String {
        entries.map { String(format: "  %6.2f 秒  ", $0.seconds) + $0.snapshot.text }.joined(separator: "\n")
    }
}

@main
@MainActor
struct ProgressiveRetryCheck {
    static func main() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["PROGRESSIVE_CHECK_ROOT"] else {
            throw CheckFailure(description: "请经 scripts/test_progressive_retry.sh 运行")
        }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let queueFolder = try refuseOutsideScratch(root: root)

        // 两条都还没开始下载，启动时由 QueueStore 自己开始。
        let keep = seededItem(videoID: "retrykeep01")
        let fresh = seededItem(videoID: "retryfresh1")
        try FileManager.default.createDirectory(at: queueFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([keep, fresh]).write(to: queueFolder.appendingPathComponent("queue.json"))

        let store = QueueStore()
        var keepTimeline = Timeline()
        var freshTimeline = Timeline()
        var reportedUnavailable = false
        let started = Date()
        while true {
            let seconds = Date().timeIntervalSince(started)
            keepTimeline.record(snapshot(store, keep.id), at: seconds)
            freshTimeline.record(snapshot(store, fresh.id), at: seconds)
            // 第二条：第一份预览一到，就像播放器报告这份预览播不了一样把它清掉。
            if !reportedUnavailable, store.isPreviewPlayable(fresh.id) {
                store.discardProgressivePlayback(for: fresh.id)
                reportedUnavailable = true
                freshTimeline.record(snapshot(store, fresh.id), at: seconds)
            }
            let finished = [keepTimeline.last, freshTimeline.last].allSatisfy {
                $0?.state == .ready || $0?.state == .failed
            }
            if finished { break }
            try failIfEnvironmentBlocks(keepTimeline, seconds: seconds)
            if seconds >= 45 {
                throw CheckFailure(description: "45 秒内没有下完。\n第一条：\n\(keepTimeline.describe())\n第二条：\n\(freshTimeline.describe())")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // 想看每一步的经过时，运行前设 PROGRESSIVE_CHECK_VERBOSE=1。
        if ProcessInfo.processInfo.environment["PROGRESSIVE_CHECK_VERBOSE"] == "1" {
            print("第一条的经过：\n\(keepTimeline.describe())\n第二条的经过：\n\(freshTimeline.describe())")
            // 断言失败会直接退出进程，先把输出写出去。
            fflush(stdout)
        }
        try checkPreviewKeptAcrossRetry(keepTimeline, root: root)
        try checkFreshPreviewAfterUnavailable(freshTimeline, root: root)
        print("progressive_retry_check=passed（真实 QueueStore，假工具，不联网：重试时预览不断、不换地址；播放器报告预览不可用后，重试拿到的新预览能用上）")
    }

    /// 自动重试时预览一直能播，而且一直是第一份预览；下完换成本地文件。
    private static func checkPreviewKeptAcrossRetry(_ timeline: Timeline, root: URL) throws {
        let log = "\n第一条的经过：\n\(timeline.describe())"
        guard let first = timeline.entries.firstIndex(where: { $0.snapshot.previewPlayable }) else {
            throw CheckFailure(description: "第一条始终没有拿到预览。\(log)")
        }
        guard let ready = timeline.entries.firstIndex(where: { $0.snapshot.state == .ready }) else {
            throw CheckFailure(description: "第一条没有下完。\(log)")
        }
        let watching = timeline.entries[first..<ready]
        try check(
            watching.contains { $0.snapshot.state == .queued && $0.snapshot.label.contains("次重试") },
            "第一条没有经过自动重试，这项检查没有测到要测的情况。\(log)"
        )
        if let gap = watching.first(where: { !$0.snapshot.previewPlayable }) {
            let at = String(format: "%.2f", gap.seconds)
            throw CheckFailure(
                description: "重试时预览被清掉了：\(at) 秒起播放器没有预览可播，正在看的人会看到画面消失、全屏退出。\(log)"
            )
        }
        let firstPreview = URL(string: "https://fixture.invalid/keep-preview-1.mp4")!
        if let switched = watching.first(where: { $0.snapshot.source != .preview(firstPreview) }) {
            let at = String(format: "%.2f", switched.seconds)
            throw CheckFailure(
                description: "重试时换了预览地址：\(at) 秒起是「\(switched.snapshot.text)」，播放器会重新载入、重新缓冲。\(log)"
            )
        }
        try checkFinishedLocally(timeline, log: log)
        try check(attempts(root: root, fixture: "keep", kind: "download") == 2, "第一条应该下载两轮（失败一次、重试下完）。\(log)")
    }

    /// 播放器报告预览不可用、预览清掉以后，重试时解析出的新预览要用上，不能因为「重试」就一概不要。
    private static func checkFreshPreviewAfterUnavailable(_ timeline: Timeline, root: URL) throws {
        let log = "\n第二条的经过：\n\(timeline.describe())"
        guard let first = timeline.entries.firstIndex(where: { $0.snapshot.previewPlayable }) else {
            throw CheckFailure(description: "第二条始终没有拿到预览。\(log)")
        }
        guard let cleared = timeline.entries[first...].firstIndex(where: { !$0.snapshot.previewPlayable }) else {
            throw CheckFailure(description: "播放器报告预览不可用以后，预览没有清掉。\(log)")
        }
        let secondPreview = URL(string: "https://fixture.invalid/fresh-preview-2.mp4")!
        try check(
            timeline.entries[cleared...].contains { $0.snapshot.source == .preview(secondPreview) },
            "播放器报告预览不可用以后，重试时解析出的新预览没有用上。\(log)"
        )
        try checkFinishedLocally(timeline, log: log)
        try check(attempts(root: root, fixture: "fresh", kind: "download") == 2, "第二条应该下载两轮（失败一次、重试下完）。\(log)")
    }

    private static func checkFinishedLocally(_ timeline: Timeline, log: String) throws {
        guard let last = timeline.last else { throw CheckFailure(description: "没有记录。\(log)") }
        try check(last.state == .ready, "最后应该是已下完。\(log)")
        guard case .localFile(let file) = last.source else {
            throw CheckFailure(description: "下完以后应该播本地文件。\(log)")
        }
        try check(file.pathExtension == "mp4", "下完以后播的不是下载的视频文件：\(file.path)\(log)")
        try check(!last.previewPlayable, "下完以后预览还算可播。\(log)")
    }

    /// 队列等网络或低电量模式暂停时，检查测不到重试；说清楚是环境原因。
    private static func failIfEnvironmentBlocks(_ timeline: Timeline, seconds: Double) throws {
        guard seconds > 10, let label = timeline.last?.label else { return }
        try check(
            label != "等待网络连接",
            "系统一直报告没有网络连接，队列不开始下载。这项检查本身不联网，但要在系统报告在线时运行。"
        )
        try check(
            label != "低电量模式已暂停",
            "低电量模式开着，队列暂停了下载。关掉低电量模式再运行这项检查。"
        )
    }

    private static func snapshot(_ store: QueueStore, _ id: UUID) -> Snapshot? {
        guard let item = store.items.first(where: { $0.id == id }) else { return nil }
        return Snapshot(
            state: item.state,
            label: item.progressLabel,
            source: store.playbackSource(for: item),
            previewPlayable: store.isPreviewPlayable(id)
        )
    }

    private static func seededItem(videoID: String) -> WatchItem {
        WatchItem(
            id: UUID(),
            urlString: "https://www.youtube.com/watch?v=\(videoID)",
            title: videoID,
            author: "",
            duration: nil,
            addedAt: Date(),
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

    private static func attempts(root: URL, fixture: String, kind: String) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("attempts", isDirectory: true).path
        )) ?? []
        return names.filter { $0.hasPrefix("\(fixture)-\(kind)-") }.count
    }

    /// 开工前核对：工具、家目录、队列文件都在临时目录里，偏好设置域是测试专用的，片库没有被指到别处。
    /// 返回队列文件所在的目录。
    private static func refuseOutsideScratch(root: URL) throws -> URL {
        let resources = Bundle.main.resourceURL?.resolvingSymlinksInPath().path ?? ""
        try check(resources.hasPrefix(root.path + "/"), "拒绝使用临时应用之外的工具")
        try check(
            Bundle.main.bundleIdentifier == "ai.openmy.seesee.tests.progressive-retry",
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
