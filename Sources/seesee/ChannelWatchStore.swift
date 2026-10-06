import Foundation

@MainActor
final class ChannelWatchStore: ObservableObject {
    static let pollInterval: TimeInterval = 4 * 60 * 60
    static let minimumPollGap: TimeInterval = 60

    @Published private(set) var subscriptions: [ChannelSubscription] = []

    private let dataFile: URL
    private let downloader: DownloadEngine
    private var timer: Timer?
    private var isPolling = false
    private var lastPollAt: Date?
    private var pollCursor = 0
    private var pendingAdded = 0

    var isOnline: () -> Bool = { true }
    var existingURLStrings: () -> Set<String> = { [] }
    var enqueue: (URL) -> Void = { _ in }
    var onPollFinished: (Int) -> Void = { _ in }

    init(dataFile: URL, downloader: DownloadEngine) {
        self.dataFile = dataFile
        self.downloader = downloader
        load()
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollAll()
            }
        }
        pollAll()
    }

    @discardableResult
    func add(_ url: URL) -> Bool {
        let canonical = ChannelLink.canonicalString(for: url)
        if subscriptions.contains(where: { $0.urlString == canonical }) {
            return false
        }
        let subscription = ChannelSubscription(
            id: UUID(),
            urlString: canonical,
            title: ChannelLink.displayTitle(for: url),
            addedAt: Date(),
            lastCheckedAt: nil
        )
        subscriptions.insert(subscription, at: 0)
        save()
        poll(subscriptionID: subscription.id)
        return true
    }

    func contains(_ url: URL) -> Bool {
        let canonical = ChannelLink.canonicalString(for: url)
        return subscriptions.contains { $0.urlString == canonical }
    }

    func remove(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        save()
    }

    func pollAll() {
        guard !isPolling else { return }
        guard isOnline() else { return }
        guard !subscriptions.isEmpty else { return }
        if let lastPollAt, Date().timeIntervalSince(lastPollAt) < Self.minimumPollGap {
            return
        }
        lastPollAt = Date()
        isPolling = true
        pollCursor = 0
        pendingAdded = 0
        pollNext()
    }

    private func poll(subscriptionID: UUID) {
        guard let subscription = subscriptions.first(where: { $0.id == subscriptionID }),
              let url = URL(string: subscription.urlString) else { return }
        downloader.fetchFlatPlaylist(
            sourceURL: url,
            limit: PlaylistListing.listingLimit
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleListing(result, for: subscriptionID, continueQueue: false)
            }
        }
    }

    private func pollNext() {
        guard pollCursor < subscriptions.count else {
            finishPolling()
            return
        }
        let subscription = subscriptions[pollCursor]
        pollCursor += 1
        guard let url = URL(string: subscription.urlString) else {
            pollNext()
            return
        }
        downloader.fetchFlatPlaylist(
            sourceURL: url,
            limit: PlaylistListing.listingLimit
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleListing(result, for: subscription.id, continueQueue: true)
            }
        }
    }

    private func handleListing(
        _ result: Swift.Result<[PlaylistListing.Entry], Error>,
        for id: UUID,
        continueQueue: Bool
    ) {
        defer {
            if continueQueue { pollNext() }
        }
        guard case .success(let listing) = result else { return }
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let plan = ChannelWatchPolicy.plan(
            listing: listing,
            known: subscriptions[index].knownURLStrings,
            existingURLStrings: existingURLStrings()
        )
        for entry in plan.toEnqueue {
            enqueue(entry.url)
        }
        if continueQueue {
            pendingAdded += plan.toEnqueue.count
        } else if !plan.toEnqueue.isEmpty {
            onPollFinished(plan.toEnqueue.count)
        }
        subscriptions[index].knownURLStrings = plan.knownURLStrings
        subscriptions[index].lastCheckedAt = Date()
        save()
    }

    private func finishPolling() {
        isPolling = false
        let added = pendingAdded
        pendingAdded = 0
        if added > 0 {
            onPollFinished(added)
        }
    }

    private func load() {
        subscriptions = ChannelSubscriptionFile.load(from: dataFile)
    }

    private func save() {
        ChannelSubscriptionFile.save(subscriptions, to: dataFile)
    }
}
