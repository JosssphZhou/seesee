import AppKit
import AVFoundation
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
    private var lastWriteSucceeded = true
    var onWriteCompleted: (() -> Void)?

    var latestWriteSucceeded: Bool { queue.sync { lastWriteSucceeded } }

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

    func flush(_ items: [WatchItem]) -> Bool {
        queue.sync {
            pendingWork?.cancel()
            pendingWork = nil
            pendingItems = items
            return writePendingItems()
        }
    }

    @discardableResult
    private func writePendingItems() -> Bool {
        guard let items = pendingItems else { return lastWriteSucceeded }
        pendingWork = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(items)
            try data.write(to: dataFile, options: .atomic)
            pendingItems = nil
            lastWriteSucceeded = true
        } catch {
            // 原件未动，失败的快照仍保留；下一次保存再试。
            lastWriteSucceeded = false
        }
        onWriteCompleted?()
        return lastWriteSucceeded
    }
}

@MainActor
final class QueueStore: ObservableObject {
    enum AddDisposition: Equatable {
        case added(UUID)
        case existing(UUID)
    }

    /// agent 经 MCP 发来的跳转：详情视图打开这一条后执行，执行完清掉。
    struct AgentSeekRequest: Equatable {
        let id = UUID()
        let itemID: UUID
        let seconds: Double
        let play: Bool
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
    @Published private(set) var agentSeekRequest: AgentSeekRequest?
    /// 下载中先播的在线预览流，只在内存里，不写进 queue.json。
    /// 重试时沿用；下完、最终失败、删除，或播放器报告预览不可用时清掉。
    @Published private var progressivePlaybackSources: [UUID: VideoPlaybackSource] = [:]

    let channelWatch: ChannelWatchStore
    private var watchCancellables = Set<AnyCancellable>()
    private let downloader = DownloadEngine()
    private let networkMonitor: NetworkMonitor
    private let powerMonitor = PowerModeMonitor()
    private let maximumConcurrentDownloads = 3
    private let dataFile: URL
    private let persistenceWriter: QueuePersistenceWriter
    private var metadataRefreshes: Set<UUID> = []
    /// 手动挪到待看的条目开始播放时的位置，用来判断「播放满 3 秒」。只在内存里。
    private var playbackStartPositions: [UUID: Double] = [:]
    private var localTranscriptionTask: Task<Void, Never>?
    private var localTranscriptionID: UUID?
    private var localTranscriptionEnabled = false
    private var localTranscriptionRetryScheduled = false
    private var transcriptionModelsObserver: NSObjectProtocol?
    private var startupTranscriptionRecoveryPending = false
    private var assetTranscriptionRecoveryPending = false
    private var loadedTranscriptionItemIDs: Set<UUID> = []
    private var explicitTranscriptionRetryIDs: Set<UUID> = []
    private var subtitleMetadata: [UUID: DownloadEngine.Metadata] = [:]
    private var subtitleMetadataRequests: Set<UUID> = []
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
    /// 升级备份失败时先只读，每次写操作或保存前重试；发布变化以刷新持续横幅。
    @Published private var isUpgradeBackupReady = true
    @Published private var isQueueWriteFailed = false
    private let defaults: UserDefaults
    private let resolveMountedVolumes: () -> [URL]
    private let volumesRoot: URL
    private var volumeObservers: [NSObjectProtocol] = []

    init() {
        networkMonitor = NetworkMonitor()
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
        observePersistenceWrites()
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
        volumesRoot: URL = MediaFolderAvailability.defaultVolumesRoot,
        networkMonitor: NetworkMonitor? = nil
    ) {
        self.networkMonitor = networkMonitor ?? NetworkMonitor()
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
        observePersistenceWrites()
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
            guard let self, count > 0, self.ensureQueueWritable() else { return }
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
        startLocalTranscriptionQueue()

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

    /// 收件箱、待看、观看中。
    var queueItems: [WatchItem] {
        items.filter { !$0.isWatched }
    }

    /// 已看完、已归档：看板做进应用之前都放在「已看」分组。
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
        guard requireQueueWrite() else { return }
        guard urls.count > 1 else {
            consider(urls[0])
            return
        }
        addBatch(urls, activatesApp: true)
    }

    /// 一次加入好几个链接：⌘V 粘贴多个链接和 agent 的 `add_links` 都走这里。
    /// 逐个加入、统计、弹一次提示；`activatesApp` 为 false 时不把 seesee 拉到前台，也不改当前选中的视频。
    @discardableResult
    func addBatch(_ urls: [URL], activatesApp: Bool) -> [AddDisposition] {
        guard requireQueueWrite() else { return [] }
        var dispositions: [AddDisposition] = []
        var addedCount = 0
        var existingCount = 0
        var subscribedCount = 0
        for url in urls {
            if ChannelLink.isSubscription(url) {
                if channelWatch.add(url) { subscribedCount += 1 }
                continue
            }
            guard let disposition = add(url, showsNotice: false, activatesApp: false, selectsItem: activatesApp) else { continue }
            dispositions.append(disposition)
            switch disposition {
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
        if activatesApp { NSApp.activate(ignoringOtherApps: true) }
        return dispositions
    }

    func confirmPendingSubscription() {
        guard requireQueueWrite() else { return }
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
        guard requireQueueWrite() else { return }
        channelWatch.remove(id)
    }

    private func consider(_ url: URL) {
        guard requireQueueWrite() else { return }
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
    ) -> AddDisposition? {
        guard requireQueueWrite() else { return nil }
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
            return .existing(existing.id)
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
            subtitleFilePath: nil,
            inInbox: true,
            hasPlayedThreeSeconds: false
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
        return .added(item.id)
    }

    func dismissIntakeNotice() {
        noticeDismissal?.cancel()
        noticeDismissal = nil
        intakeNotice = nil
    }

    func startDownload(for id: UUID) {
        guard requireQueueWrite() else { return }
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

    /// 界面「标记已看」和「移回队列」：算手动挪动。
    func toggleWatched(_ id: UUID) {
        guard requireQueueWrite() else { return }
        update(id) {
            $0.applyManualStatus($0.isWatched ? .toWatch : .watched)
        }
        save()
    }

    /// 播放到结尾：播完是用户自己的动作，算手动挪到已看完；已归档的保持已归档。
    func markWatched(_ id: UUID) {
        guard requireQueueWrite() else { return }
        update(id) {
            if $0.status == .archived {
                if $0.watchedAt == nil { $0.watchedAt = Date() }
                $0.playbackPosition = nil
            } else {
                $0.applyManualStatus(.watched)
            }
        }
        save()
    }

    /// `whilePlaying` 只在播放器正在播放时的进度回报里为 true；拖进度、点章节这类跳转是 false。
    func updatePlaybackPosition(_ seconds: Double, for id: UUID, whilePlaying: Bool = false) {
        guard seconds.isFinite, seconds >= 0, let existing = item(with: id) else { return }
        // 只读期间不补算播放。恢复后由首次真实播放回报重新建立起点。
        guard ensureQueueWritable() else {
            playbackStartPositions[id] = nil
            return
        }
        let position = seconds < 3 ? nil : seconds
        let playedThreeSeconds = notePlayback(at: seconds, for: existing, whilePlaying: whilePlaying)
        if !playedThreeSeconds, abs((existing.playbackPosition ?? 0) - (position ?? 0)) < 1 { return }
        update(id) {
            $0.playbackPosition = position
            if playedThreeSeconds { $0.notePlayedThreeSeconds() }
        }
        save()
    }

    func handlePlaybackEvent(_ event: WatchPlaybackEvent, for id: UUID) {
        switch event {
        case .started(let seconds):
            playbackStartPositions[id] = seconds.isFinite && seconds >= 0 ? seconds : nil
        case .paused, .seeked:
            playbackStartPositions[id] = nil
        }
    }

    /// 新条目和手动待看均须连续播满三秒。播放起点来自播放器事件，不读取界面快照。
    private func notePlayback(at seconds: Double, for item: WatchItem, whilePlaying: Bool) -> Bool {
        let needsProof = item.watchStatus == WatchStatus.toWatch.rawValue || (!item.statusIsManual && item.hasPlayedThreeSeconds == false)
        guard needsProof, whilePlaying else {
            playbackStartPositions[item.id] = nil
            return false
        }
        guard let start = playbackStartPositions[item.id] else {
            playbackStartPositions[item.id] = seconds
            return false
        }
        guard seconds >= start, seconds - start >= 3 else {
            if seconds < start { playbackStartPositions[item.id] = seconds }
            return false
        }
        playbackStartPositions[item.id] = nil
        return true
    }

    /// 用户改名只写 customTitle，下载和翻译不能覆盖。
    func rename(_ id: UUID, to rawTitle: String) {
        guard var changed = item(with: id), changed.rename(to: rawTitle), requireQueueWrite() else { return }
        update(id) { $0 = changed }
        save()
    }

    func reorderQueueItem(_ draggedID: UUID, relativeTo targetID: UUID, insertAfter: Bool) {
        guard requireQueueWrite() else { return }
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
                // 下载字幕查询已结束；没有拿到可读字幕时允许无字幕视频进入本机转写。
                let subtitleURL = try? result.get()
                let downloadedPaths = (try? DownloadEngine.localSubtitleFiles(for: id, in: self.mediaFolder).map(\.path)) ?? []
                self.update(id) {
                    $0.knownSubtitlePaths = Array(Set(($0.knownSubtitlePaths ?? []) + downloadedPaths)).sorted()
                    if $0.originalSubtitlePath == nil, $0.initialSubtitlePath == nil { $0.subtitleFilePath = subtitleURL?.path ?? "" }
                }
                self.save()
                self.pumpLocalTranscriptions()
            }
        }
    }

    /// 播放时重扫本地字幕：发现 agent 后补的高 rank 文件并热切换。
    /// 不 guard subtitleFilePath == nil（该字段无字幕时写 ""，nil 判断永不命中）。
    /// 已登记轨道不抢活动版本；新增外置字幕按人工登记。无轨且活动文件也不存在时写 ""。
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
        // 老队列没有清单时先登记当时已有的所有轨。断开后重连也先建清单，再认后补字幕。
        if existing.knownSubtitlePaths == nil {
            guard let files = try? DownloadEngine.localSubtitleFiles(for: id, in: mediaFolder), ensureQueueWritable() else {
                completion?(existing.subtitleFilePath ?? ""); return
            }
            update(id) { $0.knownSubtitlePaths = files.map(\.path) }
            save()
        }
        let registered = Set((item(with: id)?.knownSubtitlePaths ?? []) + [existing.originalSubtitlePath, existing.initialSubtitlePath, existing.subtitleFilePath].compactMap { $0 })
        downloader.discoverLocalSubtitle(itemID: id, in: mediaFolder, excluding: registered, externalOnly: true) { [weak self] subtitleURL in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let current = self.item(with: id) else { return }
                let newPath = subtitleURL?.path
                // 扫描期间版本可能被 agent 更新，回调再核对一次登记路径。
                let protected = (current.knownSubtitlePaths ?? []) + [current.originalSubtitlePath, current.initialSubtitlePath, current.subtitleFilePath].compactMap { $0 }
                if let newPath, !protected.contains(newPath),
                   let track = VideoSubtitleTrack(contentsOf: URL(fileURLWithPath: newPath)), self.ensureQueueWritable() {
                    self.update(id) {
                        if track.cues.contains(where: { SubtitleVersionStore.split($0).translation != nil }) || $0.originalSubtitlePath == nil {
                            $0.originalSubtitleSource = "download"
                        }
                        $0.originalSubtitlePath = track.cues.contains { SubtitleVersionStore.split($0).translation != nil } ? newPath : ($0.originalSubtitlePath ?? $0.subtitleFilePath)
                        $0.initialSubtitlePath = newPath
                        $0.subtitleFilePath = newPath
                        $0.translationSource = "author"
                        $0.initialTranslationSource = "author"
                        $0.knownSubtitlePaths = Array(Set(($0.knownSubtitlePaths ?? []) + [newPath])).sorted()
                        $0.subtitleRevision = ($0.subtitleRevision ?? 0) + 1
                        $0.transcriptionState = "not_needed"
                        $0.transcriptionError = nil
                        $0.transcriptionErrorCode = nil
                    }
                    self.save()
                } else if newPath == nil, current.originalSubtitlePath == nil, current.initialSubtitlePath == nil,
                          current.subtitleFileURL == nil, current.subtitleFilePath != "" {
                    self.update(id) { $0.subtitleFilePath = "" }
                    self.save()
                }
                // 无论是否落盘，都把扫描结果交给 UI，避免依赖 onChange（item 值可能未刷新）
                completion?(self.item(with: id)?.subtitleFilePath ?? "")
            }
        }
    }

    func remove(_ id: UUID, deleteMedia: Bool = true) {
        guard requireQueueWrite() else { return }
        cancelRecovery(for: id)
        if localTranscriptionID == id { localTranscriptionTask?.cancel() }
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
        guard ensureQueueWritable() else {
            let message = queueWriteWarning ?? MediaFolderCopy.queueUnreadable
            mediaFolderMoveMessage = message
            return .failure(message)
        }
        localTranscriptionTask?.cancel()
        isMovingMediaFolder = true
        mediaFolderMoveMessage = nil
        mediaFolderMoveProgress = nil
        defer { isMovingMediaFolder = false }

        guard flushPendingSaves() else {
            let message = queueWriteWarning ?? MediaFolderCopy.queueUnreadable
            mediaFolderMoveMessage = message
            return .failure(message)
        }
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
              let item = item(with: id), item.titleTranslationSource != .author,
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
        if item.translatedTitle != localized || item.titleTranslationSource != .author {
            update(id) { $0.setTranslatedTitle(localized, source: .author) }
            save()
        }
        return true
    }

    private func handle(_ event: DownloadEngine.Event, for id: UUID) {
        switch event {
        case .metadata(let metadata):
            subtitleMetadata[id] = metadata
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
            update(id) {
                if $0.originalSubtitlePath == nil, $0.initialSubtitlePath == nil { $0.subtitleFilePath = url.path }
            }
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
            subtitleMetadata[id] = downloaded.metadata
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
                $0.knownSubtitlePaths = Array(Set(($0.knownSubtitlePaths ?? []) + downloaded.subtitleFileURLs.map(\.path))).sorted()
                $0.thumbnailFilePath = downloaded.thumbnailFileURL?.path ?? ""
                if $0.originalSubtitlePath == nil, $0.initialSubtitlePath == nil {
                    $0.subtitleFilePath = downloaded.subtitleFileURL?.path ?? ""
                }
                $0.state = .ready
                $0.progress = 1
                $0.progressLabel = "已下载"
                $0.errorMessage = nil
            }
            save()
            originalTitleArrived(for: id, languageHint: downloaded.metadata.language)
            pumpLocalTranscriptions()
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

    // MARK: - 本机转写串行队列

    func startLocalTranscriptionQueue() {
        guard !localTranscriptionEnabled else { return }
        localTranscriptionEnabled = true
        startupTranscriptionRecoveryPending = true
        pumpLocalTranscriptions()
    }

    /// 退出时保留已落盘的 transcribing/translating，下次 load 重新排队。
    func stopLocalTranscriptionQueue() {
        localTranscriptionEnabled = false
        localTranscriptionTask?.cancel()
    }

    func retryLocalTranscription(for id: UUID) {
        guard item(with: id)?.state == .ready, requireQueueWrite() else { return }
        explicitTranscriptionRetryIDs.insert(id)
        update(id) {
            $0.transcriptionState = "queued"; $0.transcriptionError = nil; $0.transcriptionErrorCode = nil
            $0.transcriptionAutomaticRetryCount = 0
        }
        save()
        pumpLocalTranscriptions()
    }

    /// 兼容已发布字段缺错误码的失败；资源缺失不消耗其他故障的三次自动重试额度。
    private func transcriptionFailureCode(_ item: WatchItem) -> String {
        if let code = item.transcriptionErrorCode { return code }
        if item.transcriptionError?.contains("请先在设置页下载中英文语音模型") == true { return "speech_assets_missing" }
        if item.transcriptionError?.contains("本机翻译语言包未安装") == true { return "translation_assets_missing" }
        return "processing_failed"
    }

    private func recoverPendingTranscriptions() -> Bool {
        guard startupTranscriptionRecoveryPending || assetTranscriptionRecoveryPending else { return true }
        guard ensureQueueWritable() else { return false }
        var changed = false
        for item in items where item.transcriptionState == "failed" {
            guard !item.isWatched || explicitTranscriptionRetryIDs.contains(item.id) else { continue }
            let resourceFailure = ["speech_assets_missing", "translation_assets_missing"].contains(transcriptionFailureCode(item))
            let retries = max(0, item.transcriptionAutomaticRetryCount ?? 0)
            guard resourceFailure || (startupTranscriptionRecoveryPending && retries < 3) else { continue }
            update(item.id) {
                $0.transcriptionState = "queued"; $0.transcriptionError = nil; $0.transcriptionErrorCode = nil
                if !resourceFailure { $0.transcriptionAutomaticRetryCount = retries + 1 }
            }
            changed = true
        }
        startupTranscriptionRecoveryPending = false
        assetTranscriptionRecoveryPending = false
        return !changed || flushPendingSaves()
    }

    private func pumpLocalTranscriptions() {
        guard localTranscriptionEnabled, localTranscriptionTask == nil,
              !isMovingMediaFolder, !isMediaFolderDisconnected else { return }
        guard ensureQueueWritable() else {
            guard !localTranscriptionRetryScheduled else { return }
            localTranscriptionRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.localTranscriptionRetryScheduled = false
                self?.pumpLocalTranscriptions()
            }
            return
        }
        guard recoverPendingTranscriptions() else { pumpLocalTranscriptions(); return }
        let candidates = items.filter {
            $0.state == .ready && $0.localFileURL != nil && $0.subtitleFilePath != nil &&
            (!$0.isWatched || explicitTranscriptionRetryIDs.contains($0.id)) &&
            !(subtitleMetadataRequests.contains($0.id) && subtitleMetadata[$0.id] == nil) &&
            ($0.transcriptionState == nil || ["queued", "transcribing", "translating"].contains($0.transcriptionState ?? ""))
        }.sorted {
            let leftNew = !loadedTranscriptionItemIDs.contains($0.id), rightNew = !loadedTranscriptionItemIDs.contains($1.id)
            if leftNew != rightNew { return leftNew }
            if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard let candidate = candidates.first, let movie = candidate.localFileURL else { return }
        let id = candidate.id
        // 初译已完成的版本，以及本来就有的可读字幕，不再转写。
        let resumesTranslation = candidate.originalSubtitlePath != nil && candidate.initialSubtitlePath == nil && candidate.transcriptionLanguage == "en"
        if !resumesTranslation, let path = candidate.subtitleFileURL, VideoSubtitleTrack(contentsOf: path) != nil {
            // 旧 YouTube 条目补查字幕来源；不能仅凭中文文件名认作机器翻译。
            if candidate.originalSubtitlePath == nil, candidate.initialSubtitlePath == nil,
               subtitleMetadata[id] == nil, YouTubeVideoID.extract(from: candidate.urlString) != nil,
               !((try? FileManager.default.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []).contains(where: {
                   $0.lastPathComponent.hasPrefix(id.uuidString + ".") && $0.deletingPathExtension().lastPathComponent.lowercased().hasSuffix("-en") && ["srt", "vtt"].contains($0.pathExtension.lowercased())
               }),
               !subtitleMetadataRequests.contains(id), let url = URL(string: candidate.urlString) {
                if (candidate.subtitleMetadataFailureCount ?? 0) >= 3 {
                    subtitleMetadata[id] = DownloadEngine.Metadata(title: candidate.title, author: candidate.author, duration: candidate.duration, chapters: [])
                } else {
                    subtitleMetadataRequests.insert(id)
                    downloader.fetchMetadata(sourceURL: url) { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self, let current = self.item(with: id) else { return }
                            switch result {
                            case .success(let metadata):
                                self.subtitleMetadata[id] = metadata
                                self.update(id) { $0.subtitleMetadataFailureCount = 0 }
                            case .failure:
                                let count = min(3, max(0, current.subtitleMetadataFailureCount ?? 0) + 1)
                                self.update(id) { $0.subtitleMetadataFailureCount = count }
                                // 前两次不登记来源，requests保留到退出，本次运行不循环查询。
                                if count >= 3 {
                                    self.subtitleMetadata[id] = DownloadEngine.Metadata(title: current.title, author: current.author, duration: current.duration, chapters: [])
                                }
                            }
                            self.save()
                            self.pumpLocalTranscriptions()
                        }
                    }
                    // 元数据在查时跳过本条，其他条目的转写无需等它。
                    DispatchQueue.main.async { [weak self] in self?.pumpLocalTranscriptions() }
                    return
                }
            }
            if subtitleMetadataRequests.contains(id), subtitleMetadata[id] == nil { return }
            if candidate.originalSubtitlePath == nil, candidate.initialSubtitlePath == nil {
                do {
                    let registered = try registerDownloadedSubtitles(candidate, selected: path, metadata: subtitleMetadata[id])
                    update(id) { $0 = registered }
                } catch {
                    update(id) { $0.transcriptionState = "failed"; $0.transcriptionError = error.localizedDescription; $0.transcriptionErrorCode = "processing_failed" }
                    explicitTranscriptionRetryIDs.remove(id)
                    save()
                    DispatchQueue.main.async { [weak self] in self?.pumpLocalTranscriptions() }
                    return
                }
            }
            update(id) { $0.transcriptionState = $0.transcriptionLanguage == nil ? "not_needed" : "ready" }
            explicitTranscriptionRetryIDs.remove(id)
            save()
            DispatchQueue.main.async { [weak self] in self?.pumpLocalTranscriptions() }
            return
        }
        update(id) { $0.transcriptionState = "queued"; $0.transcriptionError = nil }
        guard flushPendingSaves() else { pumpLocalTranscriptions(); return }
        localTranscriptionID = id
        let folder = mediaFolder
        let original = resumesTranslation ? candidate.originalSubtitlePath.map { URL(fileURLWithPath: $0) } : nil
        localTranscriptionTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.localTranscriptionTask = nil
                self.localTranscriptionID = nil
                self.explicitTranscriptionRetryIDs.remove(id)
                self.pumpLocalTranscriptions()
            }
            do {
                // 内嵌字幕存在时不用语音模型；保留媒体自身字幕。
                let asset = AVURLAsset(url: movie)
                if self.item(with: id)?.duration == nil,
                   let duration = try? await asset.load(.duration).seconds,
                   duration.isFinite, duration > 0 {
                    self.update(id) { $0.duration = duration }
                }
                if !resumesTranslation {
                    let subtitles = try await asset.loadTracks(withMediaType: .subtitle)
                    let captions = try await asset.loadTracks(withMediaType: .closedCaption)
                    if !subtitles.isEmpty || !captions.isEmpty {
                        self.update(id) { $0.transcriptionState = "not_needed" }
                        self.save()
                        return
                    }
                }
                guard #available(macOS 26, *) else {
                    self.update(id) { $0.transcriptionState = "unsupported"; $0.transcriptionError = nil }
                    self.save()
                    return
                }
                self.update(id) { $0.transcriptionState = "transcribing" }
                guard self.flushPendingSaves() else { return }
                let files = try await LocalTranscription.run(movie: movie, itemID: id, folder: folder,
                    existingOriginal: original, language: candidate.transcriptionLanguage,
                    languageFallback: candidate.transcriptionLanguageFallback ?? false) { [self] phase in
                    try await MainActor.run {
                        try Task.checkCancellation()
                        guard self.item(with: id) != nil, self.ensureQueueWritable() else {
                            throw SubtitleVersionStore.Failure(code: "queue_write_failed", message: "队列无法保存，转写稍后再试")
                        }
                        self.update(id) {
                            switch phase {
                            case .detected(let language, let fallback):
                                $0.transcriptionLanguage = language
                                $0.transcriptionLanguageFallback = fallback
                            case .originalReady(let path):
                                $0.originalSubtitlePath = path.path
                                $0.originalSubtitleSource = "apple"
                                $0.subtitleFilePath = path.path
                            case .translating: $0.transcriptionState = "translating"
                            }
                        }
                        guard self.flushPendingSaves() else {
                            throw SubtitleVersionStore.Failure(code: "queue_write_failed", message: "队列无法保存，改动保留在内存中")
                        }
                    }
                }
                try Task.checkCancellation()
                guard self.item(with: id) != nil else { return }
                self.update(id) {
                    $0.originalSubtitlePath = files.original.path
                    $0.originalSubtitleSource = "apple"
                    $0.initialSubtitlePath = files.initial?.path
                    $0.subtitleFilePath = files.initial?.path ?? files.original.path
                    $0.translationSource = files.initial == nil ? nil : "apple"
                    $0.initialTranslationSource = $0.translationSource
                    $0.subtitleRevision = ($0.subtitleRevision ?? 0) + 1
                    $0.transcriptionLanguage = files.language
                    $0.transcriptionLanguageFallback = files.languageFallback
                    $0.transcriptionState = "ready"
                    $0.transcriptionError = nil
                    $0.transcriptionErrorCode = nil
                }
                self.save()
            } catch {
                guard !Task.isCancelled, self.item(with: id) != nil else { return }
                var failureCode = "processing_failed"
                if #available(macOS 26, *) { failureCode = (error as? LocalTranscription.Failed)?.code ?? failureCode }
                self.update(id) {
                    $0.transcriptionState = "failed"; $0.transcriptionError = error.localizedDescription
                    $0.transcriptionErrorCode = failureCode
                }
                self.save()
            }
        }
    }

    /// yt-dlp 原下载轨不动，双语显示轨另存。机器来源来自元数据或 YouTube 明确的翻译语言后缀。
    private func registerDownloadedSubtitles(_ item: WatchItem, selected: URL, metadata: DownloadEngine.Metadata?) throws -> WatchItem {
        let folder = selected.deletingLastPathComponent()
        let prefix = item.id.uuidString + "."
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && ["srt", "vtt"].contains($0.pathExtension.lowercased()) && VideoSubtitleTrack(contentsOf: $0) != nil }
            .sorted { SubtitleTrackRank.value(for: $0) < SubtitleTrackRank.value(for: $1) }
        func language(_ url: URL) -> String { String(url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count)) }
        let english = files.first { language($0).lowercased().hasPrefix("en") }
        let chinese = files.filter { language($0).lowercased().hasPrefix("zh") }
        let manual = chinese.first { metadata?.subtitleLanguages.contains(language($0)) == true }
        let translated = manual ?? chinese.first
        var updated = item
        updated.originalSubtitleSource = "download"
        if updated.knownSubtitlePaths == nil {
            updated.knownSubtitlePaths = try DownloadEngine.localSubtitleFiles(for: item.id, in: folder).map(\.path)
        }
        updated.transcriptionState = "not_needed"
        guard let translated else {
            updated.originalSubtitlePath = selected.path
            return updated
        }
        if metadata?.language?.lowercased().hasPrefix("zh") == true {
            updated.originalSubtitlePath = translated.path
            updated.subtitleFilePath = translated.path
            return updated
        }
        let isYouTube = YouTubeVideoID.extract(from: item.urlString) != nil
        let automatic = manual == nil && isYouTube && (
            metadata?.automaticCaptionLanguages.contains(language(translated)) == true ||
            language(translated).lowercased().hasSuffix("-en")
        )
        updated.translationSource = automatic ? "youtube_auto" : "author"
        updated.initialTranslationSource = updated.translationSource
        updated.initialSubtitlePath = translated.path
        let track = VideoSubtitleTrack(contentsOf: translated)!
        let bilingual = track.cues.contains { SubtitleVersionStore.split($0).translation != nil }
        updated.originalSubtitlePath = bilingual ? translated.path : english?.path
        updated.subtitleFilePath = translated.path
        updated.subtitleRevision = (item.subtitleRevision ?? 0) + 1
        // 首次显示也按相同句块生成，避免播放器仍读碎片而 MCP 已按句块编号。
        let display = folder.appendingPathComponent("\(item.id.uuidString).initial-display-\(UUID().uuidString).vtt")
        try SubtitleVersionStore.write(SubtitleVersionStore.initialCues(updated), to: display)
        updated.subtitleFilePath = display.path
        return updated
    }

    // MARK: - agent 经 MCP 的读写

    /// queue.json 读不出来时 `save()` 什么都不写，agent 的写操作要整个拒绝，不能回答成功。
    var acceptsAgentWrites: Bool { !isQueueFileUnreadable && isUpgradeBackupReady && !queueWriteFailed }
    func prepareAgentWrites() -> Bool { ensureQueueWritable() }
    var upgradeBackupFailed: Bool { !isUpgradeBackupReady }
    var queueWriteFailed: Bool { isQueueWriteFailed || !persistenceWriter.latestWriteSucceeded }
    static let backupFailureMessage = "无法备份数据，改动不会保存"
    var queueWriteWarning: String? {
        if upgradeBackupFailed { return Self.backupFailureMessage }
        return isQueueWriteFailed ? "无法保存数据，改动尚未保存" : nil
    }

    func item(with id: UUID) -> WatchItem? {
        items.first { $0.id == id }
    }

    /// 把这些条目手动挪到 `target`。调用方先确认编号都存在；一次调用只存一次盘。
    /// 返回挪动前的条目，顺序和 `ids` 相同；已经手动定在 `target` 的不改，不出现在结果里。
    func moveItems(_ ids: [UUID], to target: WatchStatus) -> [WatchItem] {
        guard requireQueueWrite() else { return [] }
        var before: [WatchItem] = []
        for id in ids {
            guard let existing = item(with: id) else { continue }
            if existing.status == target, existing.statusIsManual { continue }
            before.append(existing)
            update(id) { $0.applyManualStatus(target) }
        }
        if !before.isEmpty { save() }
        return before
    }

    /// 整组替换 agent 写的章节；空数组删掉 agent 的章节，目录回到视频自带的。调用方先确认没有用户改过的章节。
    func replaceAgentChapters(_ chapters: [VideoChapter], for id: UUID) {
        guard requireQueueWrite() else { return }
        update(id) { $0.agentChapters = chapters.isEmpty ? nil : chapters }
        save()
    }

    func subtitleSnapshot(for id: UUID) throws -> SubtitleVersionStore.Snapshot {
        guard let item = item(with: id) else { throw SubtitleVersionStore.Failure(code: "not_found", message: "条目不存在") }
        return try SubtitleVersionStore.snapshot(item)
    }

    /// 完整译文替换和初译退回都先通过统一写入保护，再等待真实 queue.json 写盘。
    @discardableResult
    func writeSubtitleTranslations(_ translations: [SubtitleVersionStore.Translation], revision: String, for id: UUID) throws -> SubtitleVersionStore.Snapshot {
        try requireSubtitleWrite()
        guard let existing = item(with: id) else { throw SubtitleVersionStore.Failure(code: "not_found", message: "条目不存在") }
        let updated = try SubtitleVersionStore.writing(translations, revision: revision, item: existing)
        update(id) { $0 = updated }
        guard flushPendingSaves() else { throw SubtitleVersionStore.Failure(code: "queue_write_failed", message: "无法保存队列，改动保留在内存中，下次保存再试") }
        return try subtitleSnapshot(for: id)
    }

    @discardableResult
    func restoreInitialTranslation(for id: UUID) throws -> SubtitleVersionStore.Snapshot {
        try requireSubtitleWrite()
        guard let existing = item(with: id) else { throw SubtitleVersionStore.Failure(code: "not_found", message: "条目不存在") }
        let updated = try SubtitleVersionStore.restoring(existing)
        update(id) { $0 = updated }
        guard flushPendingSaves() else { throw SubtitleVersionStore.Failure(code: "queue_write_failed", message: "无法保存队列，改动保留在内存中，下次保存再试") }
        return try subtitleSnapshot(for: id)
    }

    private func requireSubtitleWrite() throws {
        guard prepareAgentWrites() else {
            let code = upgradeBackupFailed ? "queue_backup_failed" : (queueWriteFailed ? "queue_write_failed" : "queue_unreadable")
            throw SubtitleVersionStore.Failure(code: code, message: queueWriteWarning ?? "队列无法读取")
        }
    }

    /// 打开这一条并让详情视图跳到 `seconds`。不把 seesee 拉到前台。
    func requestAgentSeek(to seconds: Double, play: Bool, for id: UUID) -> AgentSeekRequest {
        let request = AgentSeekRequest(itemID: id, seconds: seconds, play: play)
        agentSeekRequest = request
        selection = id
        return request
    }

    func finishAgentSeekRequest(_ requestID: UUID) {
        guard agentSeekRequest?.id == requestID else { return }
        agentSeekRequest = nil
    }

    private func update(_ id: UUID, change: (inout WatchItem) -> Void) {
        guard ensureQueueWritable() else { return }
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
        guard FileManager.default.fileExists(atPath: dataFile.path) else {
            QueueUpgradeBackup.markCurrent(defaults)
            return
        }
        guard let data = try? Data(contentsOf: dataFile),
              let decoded = MediaFolderMoveRecovery.decodeQueue(data) else {
            // 读不出来就当作无法判断：列表先空着，但不拿空列表覆盖原文件。
            isQueueFileUnreadable = true
            items = []
            mediaFolderMoveMessage = MediaFolderCopy.queueUnreadable
            return
        }
        isQueueFileUnreadable = false
        items = decoded.map { item in
            var migrated = item
            migrated.adoptLegacyTitle()
            if migrated.originalSubtitleSource == nil, migrated.originalSubtitlePath != nil {
                migrated.originalSubtitleSource = migrated.originalCorrectable ? "apple" : "download"
            }
            return migrated
        }
        loadedTranscriptionItemIDs = Set(items.map(\.id))
        isUpgradeBackupReady = QueueUpgradeBackup.backUpIfNeeded(dataFile: dataFile, data: data, defaults: defaults)
        if !isUpgradeBackupReady { persistenceWriter.cancelPending() }
        if isUpgradeBackupReady {
            var catalogued = false
            if !isMediaFolderDisconnected {
                for index in items.indices where items[index].state == .ready && items[index].knownSubtitlePaths == nil {
                    if let files = try? DownloadEngine.localSubtitleFiles(for: items[index].id, in: mediaFolder) {
                        items[index].knownSubtitlePaths = files.map(\.path)
                        catalogued = true
                    }
                }
            }
            for index in items.indices where ["transcribing", "translating"].contains(items[index].transcriptionState ?? "") {
                items[index].transcriptionState = "queued"
                items[index].transcriptionError = nil
            }
            if catalogued { save() }
        }
    }

    private func save() {
        guard ensureQueueWritable() else { return }
        persistenceWriter.schedule(items)
    }

    @discardableResult
    func flushPendingSaves() -> Bool {
        guard ensureQueueWritable(retryFailedWrite: false) else { return false }
        let saved = persistenceWriter.flush(items)
        refreshPersistenceState()
        return saved
    }

    private func observePersistenceWrites() {
        transcriptionModelsObserver = NotificationCenter.default.addObserver(forName: TranscriptionModelStatus.assetsAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.assetTranscriptionRecoveryPending = true
                _ = self.recoverPendingTranscriptions()
                self.pumpLocalTranscriptions()
            }
        }
        persistenceWriter.onWriteCompleted = { [weak self] in
            DispatchQueue.main.async { self?.refreshPersistenceState() }
        }
    }

    deinit {
        if let transcriptionModelsObserver { NotificationCenter.default.removeObserver(transcriptionModelsObserver) }
    }

    private func refreshPersistenceState() {
        // 回报时读取 writer 的最新结果，避免旧的异步失败把已成功重试的提示重新打开。
        let failed = !persistenceWriter.latestWriteSucceeded
        if isQueueWriteFailed != failed { isQueueWriteFailed = failed }
        if failed { dismissIntakeNotice() }
    }

    /// 重试时只备份磁盘原件，不能把已改动的内存队列当作升级前数据。
    /// 各写入口和保存共享这一判断；进度及后台更新只读时静默返回。
    private func ensureQueueWritable(retryFailedWrite: Bool = true) -> Bool {
        guard !isQueueFileUnreadable else { return false }
        if !isUpgradeBackupReady {
            guard let original = try? Data(contentsOf: dataFile),
                  MediaFolderMoveRecovery.decodeQueue(original) != nil else { return false }
            isUpgradeBackupReady = QueueUpgradeBackup.backUpIfNeeded(dataFile: dataFile, data: original, defaults: defaults)
        }
        guard isUpgradeBackupReady else { return false }
        if retryFailedWrite {
            refreshPersistenceState()
            if isQueueWriteFailed {
                let saved = persistenceWriter.flush(items)
                refreshPersistenceState()
                return saved
            }
        }
        return true
    }

    private func requireQueueWrite() -> Bool {
        guard ensureQueueWritable() else {
            dismissIntakeNotice()
            lastIntakeError = queueWriteWarning ?? MediaFolderCopy.queueUnreadable
            return false
        }
        return true
    }
}

/// 第一次用新格式保存前，把旧的 queue.json 复制一份留在同目录，文件名带日期。
/// 标题和待播清单状态共用 queueFormatVersion；已有标题备份不代替本次格式升级备份。
enum QueueUpgradeBackup {
    static let formatVersionKey = "queueFormatVersion"
    static let currentFormatVersion = 8
    static let filePrefix = "queue-升级前备份-"

    /// 只在偏好设置里的格式版本低于当前版本、而且 queue.json 读得出来时备份；备份写成功才记下新版本。
    @discardableResult
    static func backUpIfNeeded(dataFile: URL, data: Data, defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard defaults.integer(forKey: formatVersionKey) < currentFormatVersion else { return true }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var backup = dataFile.deletingLastPathComponent()
            .appendingPathComponent("\(filePrefix)\(formatter.string(from: now)).json")
        if FileManager.default.fileExists(atPath: backup.path) {
            backup = dataFile.deletingLastPathComponent()
                .appendingPathComponent("\(filePrefix)\(formatter.string(from: now))-\(UUID().uuidString).json")
        }
        // 原子写入：中途失败不会留下半截备份。保留同一秒内其他升级的备份。
        guard (try? data.write(to: backup, options: .atomic)) != nil else { return false }
        markCurrent(defaults)
        return true
    }

    /// 还没有 queue.json（新装）时没有旧数据要备份，直接记成当前版本。
    static func markCurrent(_ defaults: UserDefaults) {
        defaults.set(currentFormatVersion, forKey: formatVersionKey)
    }
}
