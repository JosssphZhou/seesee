import AppKit
import Combine
import Foundation
import os.log

private let progressivePlaybackLog = OSLog(subsystem: "ai.openmy.seesee", category: "progressive-playback")
private let localizedTitleLog = OSLog(subsystem: "ai.openmy.seesee", category: "title-translation")

private final class QueuePersistenceWriter {
    private let dataFile: URL
    private let queue = DispatchQueue(label: "ai.openmy.seesee.persistence", qos: .utility)
    private var pendingItems: [WatchItem]?
    private var pendingWork: DispatchWorkItem?

    init(dataFile: URL) {
        self.dataFile = dataFile
    }

    func schedule(_ items: [WatchItem]) {
        queue.async { [weak self] in
            guard let self else { return }
            pendingItems = items
            pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.writePendingItems()
            }
            pendingWork = work
            queue.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    /// 丢掉还没落盘的写入：发现 queue.json 读不出来时用，免得延迟写入随后把它覆盖。
    func cancelPending() {
        queue.sync {
            pendingWork?.cancel()
            pendingWork = nil
            pendingItems = nil
        }
    }

    func flush(_ items: [WatchItem]) {
        queue.sync {
            pendingWork?.cancel()
            pendingWork = nil
            pendingItems = items
            writePendingItems()
        }
    }

    private func writePendingItems() {
        guard let items = pendingItems else { return }
        pendingItems = nil
        pendingWork = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: dataFile, options: .atomic)
    }
}

@MainActor
final class QueueStore: ObservableObject {
    private enum AddDisposition {
        case added
        case existing
    }

    struct IntakeNotice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
        let systemImage: String
    }

    @Published private(set) var items: [WatchItem] = []
    @Published var selection: UUID?
    @Published var lastIntakeError: String?
    @Published private(set) var intakeNotice: IntakeNotice?
    @Published var pendingSubscriptionURL: URL?
    /// 下载中先播的在线预览流，只在内存里，不写进 queue.json。
    /// 重试时沿用；下完、最终失败、删除，或播放器报告预览不可用时清掉。
    @Published private var progressivePlaybackSources: [UUID: VideoPlaybackSource] = [:]

    let channelWatch: ChannelWatchStore
    private var watchCancellables = Set<AnyCancellable>()
    private let downloader = DownloadEngine()
    private let networkMonitor = NetworkMonitor()
    private let powerMonitor = PowerModeMonitor()
    private let maximumConcurrentDownloads = 3
    private let dataFile: URL
    private let persistenceWriter: QueuePersistenceWriter
    private var metadataRefreshes: Set<UUID> = []
    private var thumbnailRefreshes: Set<UUID> = []
    private var subtitleRefreshes: Set<UUID> = []
    private var noticeDismissal: Task<Void, Never>?
    private var retryAttempts: [UUID: Int] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var waitingForNetwork: Set<UUID> = []
    private var waitingForPower: Set<UUID> = []
    private var powerCancellationIDs: Set<UUID> = []
    /// 标题翻译：本次运行里已经收到原标题的条目、正在本机翻译的条目。
    private var titleArrivedIDs: Set<UUID> = []
    private var titleTranslationsInFlight: Set<UUID> = []
    /// 作者中文标题：已经问过的条目、等着凑一批去问的条目（条目 → YouTube 视频编号）、问回来的结果。
    private var localizedTitleRequestedIDs: Set<UUID> = []
    private var localizedTitleBatch: [UUID: String] = [:]
    private var localizedTitleBatchTask: Task<Void, Never>?
    private var localizedTitleCandidates: [UUID: String] = [:]
    @Published private(set) var mediaFolder: URL
    @Published private(set) var isMediaFolderDisconnected = false
    @Published private(set) var mediaFolderMoveProgress: MediaLibraryMoveProgress?
    @Published private(set) var mediaFolderMoveMessage: String?
    /// 切换后旧位置还留着的那份片库；用户在访达里删空后不再显示。
    @Published private(set) var previousMediaFolder: URL?
    private var isMovingMediaFolder = false
    /// queue.json 在但读不出来或解码失败：无法判断，本次运行不写它，也不更改片库位置。
    private var isQueueFileUnreadable = false
    /// 旧格式 queue.json 的升级前备份没写成时，留着原文件的字节。每次要保存前先重试备份，
    /// 成功以前不保存、不搬移片库，用户的写操作在改内存之前就拒绝。
    private var pendingUpgradeBackup: Data?
    @Published private(set) var upgradeBackupFailed = false
    static let backupFailureMessage = "无法备份数据，改动不会保存"
    var queueWriteWarning: String? { upgradeBackupFailed ? Self.backupFailureMessage : nil }
    private let defaults: UserDefaults
    private let resolveMountedVolumes: () -> [URL]
    private let volumesRoot: URL
    private var volumeObservers: [NSObjectProtocol] = []

    init() {
        let fileManager = FileManager.default
        let applicationSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let moviesRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
        let applicationSupport = AppFolders.applicationSupport(root: applicationSupportRoot)
        dataFile = applicationSupport.appendingPathComponent("queue.json")
        persistenceWriter = QueuePersistenceWriter(dataFile: dataFile)
        defaults = .standard
        volumesRoot = MediaFolderAvailability.defaultVolumesRoot
        resolveMountedVolumes = { MediaFolderAvailability.liveMountedVolumes() }
        // 上次更改位置没做完就先退回旧位置，再按（可能已退回的）偏好定片库目录。
        let recovery = MediaFolderMoveRecovery.rollBackPendingMove(
            beside: dataFile,
            defaults: .standard,
            mountedVolumes: MediaFolderAvailability.liveMountedVolumes()
        )
        mediaFolder = MediaFolderPreference.resolve(defaults: .standard)
            ?? AppFolders.defaultMediaFolder(moviesRoot: moviesRoot)
        channelWatch = ChannelWatchStore(
            dataFile: applicationSupport.appendingPathComponent("subscriptions.json"),
            downloader: downloader
        )
        try? fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        refreshMediaFolderConnection()
        createMediaFolderIfConnected()
        load()
        showRecoveryOutcome(recovery)
        refreshPreviousMediaFolder()
        migrateQueueToNewestFirstIfNeeded()

        markInterruptedDownloads()
        save()
        selection = queueItems.first?.id ?? archivedItems.first?.id

        wireMonitors()
        scheduleLaunchMediaFolderMoveIfNeeded()
        backfillUnwatchedTitles()
    }

    /// 测试用最小注入初始化：直接指定数据文件与媒体目录，跳过监控接线，
    /// 便于在隔离目录里通过真实 `remove()` 验证删除接线。生产一律走无参 `init()`。
    init(
        dataFile: URL,
        mediaFolder: URL,
        defaults: UserDefaults = .standard,
        mountedVolumeURLs: [URL]? = nil,
        volumesRoot: URL = MediaFolderAvailability.defaultVolumesRoot
    ) {
        self.dataFile = dataFile
        self.persistenceWriter = QueuePersistenceWriter(dataFile: dataFile)
        self.defaults = defaults
        self.volumesRoot = volumesRoot
        self.resolveMountedVolumes = {
            if let mountedVolumeURLs { return mountedVolumeURLs }
            return MediaFolderAvailability.liveMountedVolumes()
        }
        let recovery = MediaFolderMoveRecovery.rollBackPendingMove(
            beside: dataFile,
            defaults: defaults,
            mountedVolumes: mountedVolumeURLs ?? MediaFolderAvailability.liveMountedVolumes(),
            volumesRoot: volumesRoot
        )
        self.mediaFolder = mediaFolder
        self.channelWatch = ChannelWatchStore(
            dataFile: dataFile.deletingLastPathComponent().appendingPathComponent("subscriptions.json"),
            downloader: downloader
        )
        refreshMediaFolderConnection()
        createMediaFolderIfConnected()
        load()
        showRecoveryOutcome(recovery)
        refreshPreviousMediaFolder()
    }

    private func wireMonitors() {
        channelWatch.isOnline = { [weak self] in self?.networkMonitor.isOnline ?? false }
        channelWatch.existingURLStrings = { [weak self] in Set(self?.items.map(\.urlString) ?? []) }
        channelWatch.enqueue = { [weak self] url in
            self?.add(url, showsNotice: false, activatesApp: false, selectsItem: false)
        }
        channelWatch.onPollFinished = { [weak self] count in
            guard let self, count > 0 else { return }
            self.showIntakeNotice(
                title: "订阅有更新",
                detail: count == 1 ? "已加入 1 个新视频" : "已加入 \(count) 个新视频",
                systemImage: "dot.radiowaves.up.forward"
            )
        }
        channelWatch.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &watchCancellables)
        networkMonitor.onBecameOnline = { [weak self] in
            self?.resumeWaitingDownloads()
            self?.channelWatch.pollAll()
        }
        networkMonitor.start()
        powerMonitor.onChange = { [weak self] enabled in
            if enabled {
                self?.pauseDownloadsForLowPowerMode()
            } else {
                self?.resumePowerPausedDownloads()
            }
        }
        powerMonitor.start()
        observeVolumeChanges()

        let resumable = items.filter { $0.state == .queued }.map(\.id)
        let missingChapterMetadata = items.filter { $0.state == .ready && $0.chapters == nil }.map(\.id)
        let missingThumbnails = items.filter { $0.state == .ready && $0.thumbnailFilePath == nil }.map(\.id)
        let missingSubtitles = items.filter { $0.state == .ready && $0.subtitleFilePath == nil }.map(\.id)
        DispatchQueue.main.async { [weak self] in
            resumable.forEach { self?.startDownload(for: $0) }
            missingChapterMetadata.forEach { self?.refreshChapterMetadata(for: $0) }
            missingThumbnails.forEach { self?.refreshThumbnail(for: $0) }
            missingSubtitles.forEach { self?.refreshSubtitle(for: $0) }
            self?.channelWatch.start()
        }
    }

    var queueItems: [WatchItem] {
        items.filter { !$0.isWatched }
    }

    var archivedItems: [WatchItem] {
        items
            .filter(\.isWatched)
            .sorted { ($0.watchedAt ?? $0.addedAt) > ($1.watchedAt ?? $1.addedAt) }
    }

    var selectedItem: WatchItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    /// 右侧播放器当前该播的片源，规则见 `PlayerReadyDecision.source`。
    func playbackSource(for item: WatchItem) -> PlayerReadyDecision.Source {
        PlayerReadyDecision.source(
            state: item.state,
            previewURL: progressivePlaybackSources[item.id]?.videoURL,
            localFileURL: item.localFileURL
        )
    }

    /// 这一条现在能不能播预览：没下完（下载中，或重试倒计时、等网络、低电量暂停这几种排队），
    /// 并且已经拿到预览流时为 true。下完、失败、删除，或预览流拿不到、播放器报告不可用时为 false。
    /// 读的是 `@Published` 的队列和预览流，值变化会触发界面刷新；不查磁盘，每一行都可以调用。
    func isPreviewPlayable(_ id: UUID) -> Bool {
        guard let item = item(with: id) else { return false }
        // 是不是预览只取决于状态和预览流，本地文件在不在不影响结果，所以这里不查磁盘。
        return PlayerReadyDecision.source(
            state: item.state,
            previewURL: progressivePlaybackSources[id]?.videoURL,
            localFileURL: nil
        ).isPreview
    }

    func discardProgressivePlayback(for id: UUID) {
        progressivePlaybackSources.removeValue(forKey: id)
    }

    func accept(_ incoming: URL) {
        guard let webURL = URLIntake.resolve(incoming) else {
            lastIntakeError = "拖入的内容里没有网页链接。"
            return
        }
        consider(webURL)
    }

    func accept(rawValue: String) {
        let urls = URLIntake.webURLs(from: rawValue)
        guard !urls.isEmpty else {
            lastIntakeError = "这段文字里没有找到 HTTP 或 HTTPS 链接。"
            return
        }
        guard acceptsUserWrite() else { return }
        guard urls.count > 1 else {
            consider(urls[0])
            return
        }

        var addedCount = 0
        var existingCount = 0
        var subscribedCount = 0
        for url in urls {
            if ChannelLink.isSubscription(url) {
                if channelWatch.add(url) { subscribedCount += 1 }
                continue
            }
            switch add(url, showsNotice: false, activatesApp: false) {
            case .added: addedCount += 1
            case .existing: existingCount += 1
            }
        }
        lastIntakeError = nil

        if addedCount > 0 {
            let extra = [
                existingCount > 0 ? "\(existingCount) 个已在待播清单中" : nil,
                subscribedCount > 0 ? "\(subscribedCount) 个频道已订阅" : nil
            ].compactMap { $0 }.joined(separator: " · ")
            let duplicateDetail = extra.isEmpty ? "" : " · \(extra)"
            let detail: String
            let systemImage: String
            if isMediaFolderDisconnected {
                detail = "\(MediaFolderCopy.disconnected)\(duplicateDetail)"
                systemImage = "externaldrive.badge.xmark"
            } else if powerMonitor.isLowPowerModeEnabled {
                detail = "已排队，等低电量模式关闭后开始\(duplicateDetail)"
                systemImage = "battery.25"
            } else if networkMonitor.isOnline {
                detail = "已加入下载队列\(duplicateDetail)"
                systemImage = "arrow.down.circle.fill"
            } else {
                detail = "等待网络连接\(duplicateDetail)"
                systemImage = "wifi.slash"
            }
            showIntakeNotice(
                title: "已加入 \(addedCount) 个视频",
                detail: detail,
                systemImage: systemImage
            )
        } else if subscribedCount > 0 {
            showIntakeNotice(
                title: subscribedCount == 1 ? "已加入订阅" : "已加入 \(subscribedCount) 个订阅",
                detail: "有新视频会自动入队",
                systemImage: "dot.radiowaves.up.forward"
            )
        } else {
            showIntakeNotice(
                title: "已在队列中",
                detail: "粘贴的 \(existingCount) 个链接都已在待播清单中",
                systemImage: "checkmark.circle.fill"
            )
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func confirmPendingSubscription() {
        guard let url = pendingSubscriptionURL else { return }
        pendingSubscriptionURL = nil
        if channelWatch.add(url) {
            showIntakeNotice(
                title: "已加入订阅",
                detail: "有新视频会自动入队 · \(ChannelLink.displayTitle(for: url))",
                systemImage: "dot.radiowaves.up.forward"
            )
        } else {
            showIntakeNotice(
                title: "已在订阅中",
                detail: ChannelLink.displayTitle(for: url),
                systemImage: "checkmark.circle.fill"
            )
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancelPendingSubscription() {
        pendingSubscriptionURL = nil
    }

    func removeSubscription(_ id: UUID) {
        channelWatch.remove(id)
    }

    private func consider(_ url: URL) {
        guard acceptsUserWrite() else { return }
        if ChannelLink.isSubscription(url) {
            lastIntakeError = nil
            if channelWatch.contains(url) {
                showIntakeNotice(
                    title: "已在订阅中",
                    detail: ChannelLink.displayTitle(for: url),
                    systemImage: "checkmark.circle.fill"
                )
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            pendingSubscriptionURL = url
            return
        }
        add(url)
    }

    @discardableResult
    private func add(
        _ url: URL,
        showsNotice: Bool = true,
        activatesApp: Bool = true,
        selectsItem: Bool = true
    ) -> AddDisposition {
        let canonical = URLIntake.canonicalString(for: url)
        if let existing = items.first(where: { $0.urlString == canonical }) {
            if selectsItem { selection = existing.id }
            if existing.state == .failed || existing.state == .queued { startDownload(for: existing.id) }
            if showsNotice {
                let detail = existing.state == .failed || existing.state == .queued
                    ? "正在重试 \(existing.titleDisplay.primary)"
                    : "\(existing.titleDisplay.primary) 已经保存过了"
                showIntakeNotice(
                    title: "已在队列中",
                    detail: detail,
                    systemImage: "checkmark.circle.fill"
                )
            }
            if activatesApp { NSApp.activate(ignoringOtherApps: true) }
            return .existing
        }

        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? "视频"
        var item = WatchItem(
            id: UUID(),
            urlString: canonical,
            title: host,
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
        // 元数据到之前先用网址的主机名占位。每个新条目都带原标题，下次启动就不会被当成旧格式再备份。
        item.originalTitle = host
        items.insert(item, at: 0)
        if selectsItem { selection = item.id }
        lastIntakeError = nil
        save()
        startDownload(for: item.id)
        let current = self.item(with: item.id)
        let isDisconnected = current?.progressLabel == MediaFolderCopy.disconnected
        let isPowerPaused = current?.progressLabel == "低电量模式已暂停"
        let isOnline = networkMonitor.isOnline
        if showsNotice {
            showIntakeNotice(
                title: "已加入队列",
                detail: isDisconnected
                    ? MediaFolderCopy.disconnected
                    : (isPowerPaused
                        ? "低电量模式开启中，已暂停"
                        : (isOnline ? "正在下载 \(item.title)" : "等待网络连接")),
                systemImage: isDisconnected
                    ? "externaldrive.badge.xmark"
                    : (isPowerPaused ? "battery.25" : (isOnline ? "arrow.down.circle.fill" : "wifi.slash"))
            )
        }
        if activatesApp { NSApp.activate(ignoringOtherApps: true) }
        return .added
    }

    func dismissIntakeNotice() {
        noticeDismissal?.cancel()
        noticeDismissal = nil
        intakeNotice = nil
    }

    func startDownload(for id: UUID) {
        guard let item = item(with: id), item.state != .downloading else { return }
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts[id] = 0
        waitingForNetwork.remove(id)
        waitingForPower.remove(id)
        if holdDownloadIfMediaFolderUnavailable(id) { return }
        guard !powerMonitor.isLowPowerModeEnabled else {
            waitForPower(id)
            return
        }
        guard networkMonitor.isOnline else {
            waitForConnection(id, message: item.errorMessage)
            return
        }
        let isRetry = item.progress > 0 || item.errorMessage != nil || item.progressLabel != "排队中"
        beginDownload(for: id, isRetry: isRetry)
    }

    private func beginDownload(for id: UUID, isRetry: Bool) {
        if holdDownloadIfMediaFolderUnavailable(id) { return }
        if powerMonitor.isLowPowerModeEnabled {
            waitForPower(id)
            return
        }
        guard let item = item(with: id), item.state != .downloading,
              let url = URL(string: item.urlString) else { return }
        guard activeDownloadCount < maximumConcurrentDownloads else {
            update(id) {
                $0.state = .queued
                $0.progressLabel = "等待下载槽位"
            }
            save()
            return
        }
        // 重试时不清预览（上游在这里清）：正在看的人接着看原来的预览流，播放器不消失、不退出全屏。
        update(id) {
            $0.state = .downloading
            $0.progressLabel = isRetry ? "继续下载…" : "准备下载…"
            $0.errorMessage = nil
        }
        save()
        os_log("download begins item=%{public}@ retry=%{public}@", log: progressivePlaybackLog, type: .default,
               id.uuidString, isRetry ? "yes" : "no")
        requestLocalizedTitle(for: id)

        downloader.start(
            itemID: id,
            sourceURL: url,
            destination: mediaFolder,
            onEvent: { [weak self] event in
                DispatchQueue.main.async { self?.handle(event, for: id) }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async { self?.finish(result, for: id) }
            }
        )
    }

    func toggleWatched(_ id: UUID) {
        guard acceptsUserWrite() else { return }
        update(id) {
            $0.watchedAt = $0.isWatched ? nil : Date()
            if $0.isWatched { $0.playbackPosition = nil }
        }
        save()
    }

    func markWatched(_ id: UUID) {
        guard ensureUpgradeBackup() else { return }
        update(id) {
            if $0.watchedAt == nil { $0.watchedAt = Date() }
            $0.playbackPosition = nil
        }
        save()
    }

    func updatePlaybackPosition(_ seconds: Double, for id: UUID) {
        // 备份没成功时续播进度不写，也不提示。
        guard seconds.isFinite, seconds >= 0, let existing = item(with: id), ensureUpgradeBackup() else { return }
        let position = seconds < 3 ? nil : seconds
        if abs((existing.playbackPosition ?? 0) - (position ?? 0)) < 1 { return }
        update(id) { $0.playbackPosition = position }
        save()
    }

    /// 用户改名只写 `customTitle`，元数据和翻译以后都不会覆盖它。
    func rename(_ id: UUID, to rawTitle: String) {
        guard var changed = item(with: id), changed.rename(to: rawTitle), acceptsUserWrite() else { return }
        update(id) { $0 = changed }
        save()
    }

    func reorderQueueItem(_ draggedID: UUID, relativeTo targetID: UUID, insertAfter: Bool) {
        guard acceptsUserWrite() else { return }
        var reorderedQueue = queueItems
        guard draggedID != targetID,
              let sourceIndex = reorderedQueue.firstIndex(where: { $0.id == draggedID }),
              reorderedQueue.contains(where: { $0.id == targetID }) else { return }
        let originalOrder = reorderedQueue.map(\.id)

        let draggedItem = reorderedQueue.remove(at: sourceIndex)
        guard let targetIndex = reorderedQueue.firstIndex(where: { $0.id == targetID }) else { return }
        let insertionIndex = min(targetIndex + (insertAfter ? 1 : 0), reorderedQueue.endIndex)
        reorderedQueue.insert(draggedItem, at: insertionIndex)
        guard reorderedQueue.map(\.id) != originalOrder else { return }

        var reorderedIterator = reorderedQueue.makeIterator()
        items = items.map { item in
            guard !item.isWatched else { return item }
            return reorderedIterator.next() ?? item
        }
        save()
    }

    func refreshChapterMetadata(for id: UUID) {
        guard !metadataRefreshes.contains(id),
              let existing = item(with: id),
              existing.state == .ready,
              existing.chapters == nil,
              let url = URL(string: existing.urlString) else { return }
        metadataRefreshes.insert(id)
        downloader.fetchMetadata(sourceURL: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.metadataRefreshes.remove(id)
                guard case .success(let metadata) = result else { return }
                self.update(id) {
                    $0.applyMetadataTitle(title: metadata.title, postText: metadata.description, author: metadata.author)
                    $0.author = metadata.author
                    $0.duration = metadata.duration
                    $0.chapters = metadata.chapters
                }
                self.save()
            }
        }
    }

    func refreshThumbnail(for id: UUID) {
        guard !isMediaFolderDisconnected, !isMovingMediaFolder else { return }
        guard !thumbnailRefreshes.contains(id),
              let existing = item(with: id),
              existing.state == .ready,
              existing.thumbnailFilePath == nil,
              let url = URL(string: existing.urlString) else { return }
        thumbnailRefreshes.insert(id)
        downloader.fetchThumbnail(
            itemID: id,
            sourceURL: url,
            destination: mediaFolder
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbnailRefreshes.remove(id)
                guard case .success(let thumbnailURL) = result else { return }
                self.update(id) { $0.thumbnailFilePath = thumbnailURL?.path ?? "" }
                self.save()
            }
        }
    }

    func refreshSubtitle(for id: UUID) {
        guard !isMediaFolderDisconnected, !isMovingMediaFolder else { return }
        guard !subtitleRefreshes.contains(id),
              let existing = item(with: id),
              existing.state == .ready,
              existing.subtitleFilePath == nil,
              let url = URL(string: existing.urlString) else { return }
        subtitleRefreshes.insert(id)
        downloader.fetchSubtitle(
            itemID: id,
            sourceURL: url,
            destination: mediaFolder
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.subtitleRefreshes.remove(id)
                guard case .success(let subtitleURL) = result else { return }
                self.update(id) { $0.subtitleFilePath = subtitleURL?.path ?? "" }
                self.save()
            }
        }
    }

    /// 播放时重扫本地字幕：发现 agent 后补的高 rank 文件并热切换。
    /// 不 guard subtitleFilePath == nil（该字段无字幕时写 ""，nil 判断永不命中）。
    /// 扫描结果与现值相同则不写不 save（幂等）。找不到字幕写 ""，严禁回写 nil。
    /// - Parameter completion: 主线程回调扫描后的有效路径（含幂等未变时），供当前界面立即重载字幕。
    func rescanLocalSubtitle(for id: UUID, completion: ((String) -> Void)? = nil) {
        guard let existing = item(with: id) else { return }
        guard !isMediaFolderDisconnected else {
            completion?(existing.subtitleFilePath ?? "")
            return
        }
        guard existing.state == .ready else {
            completion?(existing.subtitleFilePath ?? "")
            return
        }
        downloader.discoverLocalSubtitle(itemID: id, in: mediaFolder) { [weak self] subtitleURL in
            DispatchQueue.main.async {
                guard let self else { return }
                // 与 refreshSubtitle / 下载完成路径一致：找不到写空字符串，不写 nil
                let newPath = subtitleURL?.path ?? ""
                if let current = self.item(with: id), current.subtitleFilePath != newPath {
                    self.update(id) { $0.subtitleFilePath = newPath }
                    self.save()
                }
                // 无论是否落盘，都把扫描结果交给 UI，避免依赖 onChange（item 值可能未刷新）
                completion?(newPath)
            }
        }
    }

    func remove(_ id: UUID, deleteMedia: Bool = true) {
        guard acceptsUserWrite() else { return }
        cancelRecovery(for: id)
        progressivePlaybackSources.removeValue(forKey: id)
        downloader.cancel(itemID: id)
        if deleteMedia {
            deleteLocalFiles(for: id)
        }
        items.removeAll { $0.id == id }
        save()
        if selection == id {
            selection = queueItems.first?.id ?? archivedItems.first?.id
        }
    }

    /// 删除该视频的全部本地文件：同步前缀扫描删掉全部 <uuid>.* 文件，包括视频、字幕、缩略图，
    /// 以及旧版本留下的问答、批注、目录记录。
    private func deleteLocalFiles(for id: UUID) {
        let folder = mediaFolder
        let prefix = id.uuidString + "."
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func openOriginal(_ id: UUID) {
        guard let value = item(with: id)?.urlString, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealMediaFolder() {
        guard !isMediaFolderDisconnected else { return }
        NSWorkspace.shared.open(mediaFolder)
    }

    func presentMediaFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = MediaFolderCopy.changeButton
        panel.directoryURL = isMediaFolderDisconnected ? nil : mediaFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = moveMediaFolder(to: url)
    }

    @discardableResult
    func moveMediaFolder(to destination: URL, mover: MediaLibraryMover? = nil) -> MediaLibraryMoveResult {
        guard !isMovingMediaFolder else {
            return .failure("正在搬移视频")
        }
        guard ensureUpgradeBackup() else {
            mediaFolderMoveMessage = Self.backupFailureMessage
            return .failure(Self.backupFailureMessage)
        }
        // 按磁盘上当前的 queue.json 判断，不信启动时读的结果：运行中被改坏时，
        // 先 flush 会拿内存里的旧队列把它覆盖掉，之后的搬移就看不出它坏过。
        guard !isQueueFileUnreadable, queueFileDecodesOnDisk() else {
            if FileManager.default.fileExists(atPath: dataFile.path) {
                isQueueFileUnreadable = true
                persistenceWriter.cancelPending()
            }
            mediaFolderMoveMessage = MediaFolderCopy.failure(MediaFolderCopy.queueUnreadable)
            MediaFolderLog.error("move refused: queue.json unreadable on disk")
            return .failure(MediaFolderCopy.queueUnreadable)
        }
        isMovingMediaFolder = true
        mediaFolderMoveMessage = nil
        mediaFolderMoveProgress = nil
        defer { isMovingMediaFolder = false }

        flushPendingSaves()
        let previous = mediaFolder
        let used = mover ?? MediaLibraryMover(
            defaults: defaults,
            mountedVolumes: resolveMountedVolumes(),
            volumesRoot: volumesRoot
        )
        let result = used.move(
            from: mediaFolder,
            to: destination,
            dataFile: dataFile,
            hasActiveDownload: items.contains(where: { $0.state == .downloading })
        ) { [weak self] progress in
            self?.mediaFolderMoveProgress = progress
        }
        mediaFolderMoveProgress = nil

        switch result {
        case .success:
            defaults.set(previous.standardizedFileURL.path, forKey: Self.previousMediaFolderKey)
            mediaFolder = destination.standardizedFileURL
            load()
            refreshMediaFolderConnection()
            refreshPreviousMediaFolder()
            MediaFolderLog.info("move succeeded: \(destination.path); old copy kept at \(previous.path)")
        case .noOp:
            MediaFolderLog.info("move skipped: destination is the current folder")
        case .failure(let reason):
            mediaFolderMoveMessage = MediaFolderCopy.failure(reason)
            MediaFolderLog.error("move failed: \(reason)")
        }
        return result
    }

    private func queueFileDecodesOnDisk() -> Bool {
        guard let data = try? Data(contentsOf: dataFile) else { return false }
        return MediaFolderMoveRecovery.decodeQueue(data) != nil
    }

    private func showRecoveryOutcome(_ outcome: MediaFolderMoveRecoveryOutcome) {
        switch outcome {
        case .nothingPending:
            break
        case .rolledBack:
            mediaFolderMoveMessage = MediaFolderCopy.pendingMoveRolledBack
            MediaFolderLog.info("rolled back unfinished move")
        case .needsAttention(let reason):
            mediaFolderMoveMessage = reason
            MediaFolderLog.error("unfinished move needs attention: \(reason)")
        }
    }

    static let previousMediaFolderKey = "MediaFolderPreviousPath"

    /// 旧位置还在、里面还有文件时才显示；已删空或就是当前位置时清掉记录。
    func refreshPreviousMediaFolder() {
        guard let path = defaults.string(forKey: Self.previousMediaFolderKey) else {
            previousMediaFolder = nil
            return
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        if MediaFolderAvailability.isDisconnected(folder, mountedVolumes: resolveMountedVolumes(), volumesRoot: volumesRoot) {
            previousMediaFolder = nil
            return
        }
        guard folder.path != mediaFolder.standardizedFileURL.path, Self.containsAnyFile(folder) else {
            defaults.removeObject(forKey: Self.previousMediaFolderKey)
            previousMediaFolder = nil
            return
        }
        previousMediaFolder = folder
    }

    func revealPreviousMediaFolder() {
        guard let previousMediaFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([previousMediaFolder])
    }

    private static func containsAnyFile(_ folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let file as URL in enumerator {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return true
            }
        }
        return false
    }

    func refreshMediaFolderConnection() {
        let disconnected = MediaFolderAvailability.isDisconnected(
            mediaFolder,
            mountedVolumes: resolveMountedVolumes(),
            volumesRoot: volumesRoot
        )
        let changed = disconnected != isMediaFolderDisconnected
        isMediaFolderDisconnected = disconnected
        guard changed else { return }
        if disconnected {
            markQueuedAsDisconnected()
        } else {
            resumeDisconnectedDownloads()
        }
    }

    private func createMediaFolderIfConnected() {
        guard !isMediaFolderDisconnected else { return }
        try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
    }

    private func markInterruptedDownloads() {
        if isMediaFolderDisconnected {
            markQueuedAsDisconnected()
            return
        }
        for index in items.indices where items[index].state == .downloading {
            items[index].state = .queued
            items[index].progressLabel = "等待恢复"
        }
    }

    private func markQueuedAsDisconnected() {
        for index in items.indices where items[index].state == .downloading || items[index].state == .queued {
            items[index].state = .queued
            items[index].progressLabel = MediaFolderCopy.disconnected
        }
    }

    private func resumeDisconnectedDownloads() {
        let ids = items
            .filter { $0.state == .queued && $0.progressLabel == MediaFolderCopy.disconnected }
            .map(\.id)
        for id in ids {
            startDownload(for: id)
        }
    }

    @discardableResult
    private func holdDownloadIfMediaFolderUnavailable(_ id: UUID) -> Bool {
        if isMediaFolderDisconnected {
            update(id) {
                $0.state = .queued
                $0.progressLabel = MediaFolderCopy.disconnected
            }
            save()
            return true
        }
        if isMovingMediaFolder {
            return true
        }
        return false
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification]
        for name in names {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshMediaFolderConnection()
                }
            })
        }
    }

    private func scheduleLaunchMediaFolderMoveIfNeeded() {
        guard let destination = MediaFolderLaunchArguments.moveDestination() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.moveMediaFolder(to: destination)
        }
    }

    func revealLocalFile(_ id: UUID) {
        guard let path = QueueRowMeta.localFileToReveal(
            path: item(with: id)?.localFilePath,
            exists: { FileManager.default.fileExists(atPath: $0) }
        ) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func migrateQueueToNewestFirstIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: QueueOrderPolicy.versionDefaultsKey) < QueueOrderPolicy.currentVersion else {
            return
        }
        items = QueueOrderPolicy.newestFirst(items)
        defaults.set(QueueOrderPolicy.currentVersion, forKey: QueueOrderPolicy.versionDefaultsKey)
    }

    // MARK: 标题翻译

    /// 原标题到了：作者的中文标题已经问回来就用它；否则不是中文的原标题在本机翻一次。
    /// 只对本次加进来、正在下载的条目调用，旧条目不批量补翻。
    private func originalTitleArrived(for id: UUID, languageHint: String?) {
        guard let item = item(with: id) else { return }
        titleArrivedIDs.insert(id)
        if applyLocalizedTitleCandidate(for: id) { return }
        guard item.translatedTitle == nil, !titleTranslationsInFlight.contains(id) else { return }
        let original = item.resolvedOriginalTitle
        let text = QueueRowMeta.displayTitle(title: original, author: item.author)
        guard TitleLanguage.needsTranslation(text) else { return }
        let source = TitleLanguage.sourceLanguage(for: text, hint: languageHint)
        titleTranslationsInFlight.insert(id)
        Task { @MainActor [weak self] in
            let translated = await OnDeviceTitleTranslator.shared.translate(text, from: source)
            guard let self else { return }
            self.titleTranslationsInFlight.remove(id)
            // 翻译期间原标题换了、作者中文标题先到了，或者已经有译名，就不用这次的结果。
            guard let translated, let current = self.item(with: id),
                  current.resolvedOriginalTitle == original,
                  current.translatedTitle == nil,
                  !VideoTitleText.same(translated, text) else { return }
            self.update(id) { $0.setTranslatedTitle(translated, source: .onDevice) }
            self.save()
        }
    }

    /// 启动时把还没看的旧条目补翻一次：只用本机翻译，不弹语言下载提示（没装语言包就跳过），
    /// 不联网问作者标题；已看的不翻。新加入的条目由 `originalTitleArrived` 翻，这里只挑已经有原标题的。
    /// 还没翻成的条目下次启动再试；翻过的、中文的不会再翻。
    private func backfillUnwatchedTitles() {
        let candidates = items.compactMap { item -> (UUID, String, String)? in
            guard !item.isWatched, item.translatedTitle == nil,
                  item.state == .ready || item.state == .failed,
                  let original = VideoTitleText.nonEmpty(item.originalTitle),
                  original != URL(string: item.urlString)?.host?.replacingOccurrences(of: "www.", with: "")
            else { return nil }
            let text = QueueRowMeta.displayTitle(title: original, author: item.author)
            guard TitleLanguage.needsTranslation(text) else { return nil }
            return (item.id, original, text)
        }
        guard !candidates.isEmpty else { return }
        Task { @MainActor [weak self] in
            var translatedCount = 0
            for (id, original, text) in candidates {
                guard let self else { return }
                guard !self.titleTranslationsInFlight.contains(id) else { continue }
                self.titleTranslationsInFlight.insert(id)
                let source = TitleLanguage.sourceLanguage(for: text, hint: nil)
                let translated = await OnDeviceTitleTranslator.shared.translate(
                    text,
                    from: source,
                    allowsDownloadPrompt: false
                )
                self.titleTranslationsInFlight.remove(id)
                guard let translated, let current = self.item(with: id),
                      !current.isWatched,
                      current.resolvedOriginalTitle == original,
                      current.translatedTitle == nil,
                      !VideoTitleText.same(translated, text) else { continue }
                self.update(id) { $0.setTranslatedTitle(translated, source: .onDevice) }
                self.save()
                translatedCount += 1
            }
            os_log("backfill titles candidates=%d translated=%d", log: localizedTitleLog, type: .default,
                   candidates.count, translatedCount)
        }
    }

    /// YouTube 视频开始下载时顺便问作者有没有中文标题。几条一起加进来时凑成一批，只启动一次 yt-dlp。
    private func requestLocalizedTitle(for id: UUID) {
        guard !localizedTitleRequestedIDs.contains(id),
              let item = item(with: id), item.translationSource != .author,
              let videoID = YouTubeVideoID.extract(from: item.urlString) else { return }
        localizedTitleRequestedIDs.insert(id)
        localizedTitleBatch[id] = videoID
        guard localizedTitleBatchTask == nil else { return }
        localizedTitleBatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.sendLocalizedTitleBatch()
        }
    }

    private func sendLocalizedTitleBatch() {
        localizedTitleBatchTask = nil
        let batch = localizedTitleBatch
        localizedTitleBatch = [:]
        guard !batch.isEmpty else { return }
        let videoIDs = Array(Set(batch.values)).sorted()
        downloader.fetchLocalizedTitles(videoIDs: videoIDs) { [weak self] titles in
            DispatchQueue.main.async {
                guard let self else { return }
                os_log("localized titles asked=%d got=%d", log: localizedTitleLog, type: .default,
                       videoIDs.count, titles.count)
                for (id, videoID) in batch {
                    guard let title = titles[videoID] else { continue }
                    self.localizedTitleCandidates[id] = title
                    // 原标题还没到时先记着，到了再比。
                    if self.titleArrivedIDs.contains(id) { self.applyLocalizedTitleCandidate(for: id) }
                }
            }
        }
    }

    /// 作者的中文标题和原标题不同、原标题不是中文时，用它做译名，换掉本机翻译。返回用了没有。
    @discardableResult
    private func applyLocalizedTitleCandidate(for id: UUID) -> Bool {
        guard let localized = localizedTitleCandidates[id], let item = item(with: id) else { return false }
        let original = QueueRowMeta.displayTitle(title: item.resolvedOriginalTitle, author: item.author)
        guard AuthorTitle.accepts(localized: localized, original: original) else {
            localizedTitleCandidates[id] = nil
            return false
        }
        localizedTitleCandidates[id] = nil
        if item.translatedTitle != localized || item.translationSource != .author {
            update(id) { $0.setTranslatedTitle(localized, source: .author) }
            save()
        }
        return true
    }

    private func handle(_ event: DownloadEngine.Event, for id: UUID) {
        switch event {
        case .metadata(let metadata):
            update(id) {
                $0.applyMetadataTitle(title: metadata.title, postText: metadata.description, author: metadata.author)
                $0.author = metadata.author
                $0.duration = metadata.duration
                $0.chapters = metadata.chapters
            }
            save()
            originalTitleArrived(for: id, languageHint: metadata.language)
        case .progress(let progress, let label):
            update(id) {
                $0.progress = progress
                $0.progressLabel = label.isEmpty ? "下载中…" : label
            }
        case .playbackSource(let source):
            guard item(with: id)?.state == .downloading else { return }
            // 重试时会再解析出一条预览流。已经有预览就不换：换了地址，播放器要重新载入、重新缓冲。
            guard progressivePlaybackSources[id] == nil else {
                os_log("preview kept item=%{public}@ (stream from retry not used)", log: progressivePlaybackLog,
                       type: .default, id.uuidString)
                return
            }
            progressivePlaybackSources[id] = source
            os_log("preview ready item=%{public}@ format=%{public}@", log: progressivePlaybackLog, type: .default,
                   id.uuidString, Self.formatDescription(of: source.videoURL))
        case .subtitleFile(let url):
            guard item(with: id) != nil else { return }
            update(id) { $0.subtitleFilePath = url.path }
            save()
        }
    }

    /// 日志只记格式，不记带签名的完整地址：YouTube 地址的 itag 就是格式编号，其他网站记主机名。
    private static func formatDescription(of url: URL) -> String {
        let itag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "itag" }?.value
        return itag.map { "itag \($0)" } ?? (url.host ?? "unknown")
    }

    private func finish(_ result: Result<DownloadEngine.Result, Error>, for id: UUID) {
        defer { startWaitingDownloadsIfPossible() }
        switch result {
        case .success(let downloaded):
            cancelRecovery(for: id)
            // 和下面的 .ready 在同一次更新里清掉预览：正在看的话，播放器在同一个 AVPlayer 上换成本地文件。
            let hadPreview = progressivePlaybackSources.removeValue(forKey: id) != nil
            os_log("download finished item=%{public}@ previewWasActive=%{public}@", log: progressivePlaybackLog,
                   type: .default, id.uuidString, hadPreview ? "yes" : "no")
            update(id) {
                $0.applyMetadataTitle(
                    title: downloaded.metadata.title,
                    postText: downloaded.metadata.description,
                    author: downloaded.metadata.author
                )
                $0.author = downloaded.metadata.author
                $0.duration = downloaded.metadata.duration
                $0.chapters = downloaded.metadata.chapters
                $0.localFilePath = downloaded.fileURL.path
                $0.thumbnailFilePath = downloaded.thumbnailFileURL?.path ?? ""
                $0.subtitleFilePath = downloaded.subtitleFileURL?.path ?? ""
                $0.state = .ready
                $0.progress = 1
                $0.progressLabel = "已下载"
                $0.errorMessage = nil
            }
            save()
            originalTitleArrived(for: id, languageHint: downloaded.metadata.language)
        case .failure(let error):
            if powerCancellationIDs.remove(id) != nil {
                if powerMonitor.isLowPowerModeEnabled {
                    waitForPower(id, showNotice: false)
                } else if networkMonitor.isOnline {
                    waitingForPower.remove(id)
                    retryAttempts[id] = 0
                    beginDownload(for: id, isRetry: true)
                } else {
                    waitingForPower.remove(id)
                    waitForConnection(id, message: error.localizedDescription)
                }
                return
            }
            handleDownloadFailure(error, for: id)
        }
    }

    private func handleDownloadFailure(_ error: Error, for id: UUID) {
        guard item(with: id) != nil else { return }
        let message = error.localizedDescription
        let networkFailure = DownloadRetryPolicy.isNetworkFailure(
            message: message,
            isOnline: networkMonitor.isOnline
        )
        if networkFailure && !networkMonitor.isOnline {
            waitForConnection(id, message: message)
            return
        }
        scheduleRetry(for: id, message: message)
    }

    private func scheduleRetry(for id: UUID, message: String) {
        let usedRetries = retryAttempts[id] ?? 0
        guard usedRetries < DownloadRetryPolicy.maximumRetries else {
            // 最终失败：显示失败画面和「重试下载」，不再播预览。
            progressivePlaybackSources.removeValue(forKey: id)
            update(id) {
                $0.state = .failed
                $0.progressLabel = "重试 3 次后失败"
                $0.errorMessage = message
            }
            save()
            return
        }

        let attempt = usedRetries + 1
        let delay = DownloadRetryPolicy.delaySeconds(forRetry: attempt)
        retryAttempts[id] = attempt
        update(id) {
            $0.state = .queued
            $0.progressLabel = "第 \(attempt)/\(DownloadRetryPolicy.maximumRetries) 次重试，\(delay) 秒后"
            $0.errorMessage = message
        }
        save()

        retryTasks[id]?.cancel()
        retryTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.retryTasks[id] = nil
            guard !self.powerMonitor.isLowPowerModeEnabled else {
                self.waitForPower(id)
                return
            }
            guard self.networkMonitor.isOnline else {
                self.waitForConnection(id, message: message)
                return
            }
            self.beginDownload(for: id, isRetry: true)
        }
    }

    private func waitForConnection(_ id: UUID, message: String?) {
        guard item(with: id) != nil else { return }
        let wasWaiting = waitingForNetwork.contains(id)
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        waitingForNetwork.insert(id)
        update(id) {
            $0.state = .queued
            $0.progressLabel = "等待网络连接"
            $0.errorMessage = message
        }
        save()
        if !wasWaiting {
            showIntakeNotice(
                title: "下载已暂停",
                detail: "等待网络连接",
                systemImage: "wifi.slash"
            )
        }
    }

    private func resumeWaitingDownloads() {
        let persisted = items
            .filter { $0.state == .queued && $0.progressLabel == "等待网络连接" }
            .map(\.id)
        let ids = waitingForNetwork.union(persisted)
        guard !ids.isEmpty else { return }

        if powerMonitor.isLowPowerModeEnabled {
            for id in ids {
                waitingForNetwork.remove(id)
                retryAttempts[id] = 0
                waitForPower(id, showNotice: false)
            }
            showIntakeNotice(
                title: "网络已恢复",
                detail: "低电量模式下下载仍保持暂停",
                systemImage: "battery.25"
            )
            return
        }

        showIntakeNotice(
            title: "网络已恢复",
            detail: ids.count == 1 ? "继续下载" : "继续下载 \(ids.count) 个视频",
            systemImage: "wifi"
        )
        for id in ids {
            waitingForNetwork.remove(id)
            retryAttempts[id] = 0
            beginDownload(for: id, isRetry: true)
        }
    }

    private func waitForPower(_ id: UUID, showNotice: Bool = true) {
        guard item(with: id) != nil else { return }
        let wasWaiting = waitingForPower.contains(id)
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        waitingForPower.insert(id)
        update(id) {
            $0.state = .queued
            $0.progressLabel = "低电量模式已暂停"
        }
        save()
        if showNotice && !wasWaiting {
            showIntakeNotice(
                title: "下载已暂停",
                detail: "低电量模式已开启",
                systemImage: "battery.25"
            )
        }
    }

    private func pauseDownloadsForLowPowerMode() {
        let activeIDs = items.filter { $0.state == .downloading }.map(\.id)
        let retryIDs = Set(retryTasks.keys)
        let affected = Set(activeIDs).union(retryIDs)
        guard !affected.isEmpty else { return }

        for id in activeIDs {
            powerCancellationIDs.insert(id)
            waitForPower(id, showNotice: false)
            downloader.cancel(itemID: id)
        }
        for id in retryIDs where !activeIDs.contains(id) {
            waitForPower(id, showNotice: false)
        }
        showIntakeNotice(
            title: "下载已暂停",
            detail: "低电量模式已开启",
            systemImage: "battery.25"
        )
    }

    private func resumePowerPausedDownloads() {
        let persisted = items
            .filter { $0.state == .queued && $0.progressLabel == "低电量模式已暂停" }
            .map(\.id)
        let ids = waitingForPower.union(persisted)
        guard !ids.isEmpty else { return }

        if networkMonitor.isOnline {
            showIntakeNotice(
                title: "低电量模式已关闭",
                detail: ids.count == 1 ? "继续下载" : "继续下载 \(ids.count) 个视频",
                systemImage: "bolt.fill"
            )
            for id in ids {
                guard !powerCancellationIDs.contains(id) else { continue }
                waitingForPower.remove(id)
                retryAttempts[id] = 0
                beginDownload(for: id, isRetry: true)
            }
        } else {
            for id in ids {
                waitingForPower.remove(id)
                waitForConnection(id, message: item(with: id)?.errorMessage)
            }
        }
    }

    private func cancelRecovery(for id: UUID) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts.removeValue(forKey: id)
        waitingForNetwork.remove(id)
        waitingForPower.remove(id)
        powerCancellationIDs.remove(id)
    }

    private var activeDownloadCount: Int {
        items.lazy.filter { $0.state == .downloading }.count
    }

    private func startWaitingDownloadsIfPossible() {
        guard !isMediaFolderDisconnected, !isMovingMediaFolder else { return }
        guard networkMonitor.isOnline, !powerMonitor.isLowPowerModeEnabled else { return }
        let availableSlots = maximumConcurrentDownloads - activeDownloadCount
        guard availableSlots > 0 else { return }

        let waiting = items
            .filter { $0.state == .queued && $0.progressLabel == "等待下载槽位" }
            .sorted { $0.addedAt < $1.addedAt }
            .prefix(availableSlots)
        for item in waiting {
            let isRetry = item.progress > 0 || item.errorMessage != nil
            beginDownload(for: item.id, isRetry: isRetry)
        }
    }

    private func item(with id: UUID) -> WatchItem? {
        items.first { $0.id == id }
    }

    private func update(_ id: UUID, change: (inout WatchItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func showIntakeNotice(title: String, detail: String, systemImage: String) {
        noticeDismissal?.cancel()
        let notice = IntakeNotice(title: title, detail: detail, systemImage: systemImage)
        intakeNotice = notice
        noticeDismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, self?.intakeNotice?.id == notice.id else { return }
            self?.intakeNotice = nil
        }
    }

    private func load() {
        pendingUpgradeBackup = nil
        upgradeBackupFailed = false
        guard FileManager.default.fileExists(atPath: dataFile.path) else { return }
        guard let data = try? Data(contentsOf: dataFile),
              let decoded = MediaFolderMoveRecovery.decodeQueue(data) else {
            // 读不出来就当作无法判断：列表先空着，但不拿空列表覆盖原文件。
            isQueueFileUnreadable = true
            items = []
            mediaFolderMoveMessage = MediaFolderCopy.queueUnreadable
            return
        }
        isQueueFileUnreadable = false
        // 旧版本写的 queue.json：第一次按新格式保存前原样复制一份；旧的 title 当作原标题。
        if TitleFieldsMigration.backUpIfLegacy(data, beside: dataFile) == .failed {
            pendingUpgradeBackup = data
            upgradeBackupFailed = true
            persistenceWriter.cancelPending()
        }
        items = decoded.map { item in
            var migrated = item
            migrated.adoptLegacyTitle()
            return migrated
        }
    }

    private func save() {
        guard !isQueueFileUnreadable, ensureUpgradeBackup() else { return }
        persistenceWriter.schedule(items)
    }

    func flushPendingSaves() {
        guard !isQueueFileUnreadable, ensureUpgradeBackup() else { return }
        persistenceWriter.flush(items)
    }

    /// 升级前备份还没成功时再试一次。成功就解锁，这次运行积累的改动照常保存；失败返回 false。
    private func ensureUpgradeBackup() -> Bool {
        guard let data = pendingUpgradeBackup else { return true }
        guard TitleFieldsMigration.backUpIfLegacy(data, beside: dataFile) != .failed else {
            upgradeBackupFailed = true
            return false
        }
        pendingUpgradeBackup = nil
        upgradeBackupFailed = false
        return true
    }

    /// 用户的写操作（加链接、改名、标记已看、排序、删除）在改内存之前先过这一关。
    /// 备份还是写不成就拒绝，并提示改动不会保存。
    private func acceptsUserWrite() -> Bool {
        guard ensureUpgradeBackup() else {
            showIntakeNotice(title: "没有保存", detail: Self.backupFailureMessage, systemImage: "exclamationmark.triangle.fill")
            return false
        }
        return true
    }
}
