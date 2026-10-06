import Foundation

/// 在主线程执行一段代码，最多等 `timeout` 秒。
/// 返回 nil 表示主线程一直没空：这时 `body` 一定没执行，以后也不会执行。
/// 写操作靠这一点保证「回答 busy 就是什么都没改」。不能在主线程上调用。
final class MainThreadCall<Value> {
    private enum Phase {
        case waiting
        case started
        case abandoned
    }

    private let lock = NSLock()
    private var phase = Phase.waiting
    private var value: Value?
    private let done = DispatchSemaphore(value: 0)

    static func run(timeout: TimeInterval, _ body: @escaping @MainActor () -> Value) -> Value? {
        let call = MainThreadCall<Value>()
        Task { @MainActor in
            guard call.begin() else { return }
            call.finish(body())
        }
        if call.done.wait(timeout: .now() + timeout) == .success {
            return call.result()
        }
        if call.abandonIfWaiting() {
            return nil
        }
        // 主线程已经开始执行：等它做完，回答真实结果。
        call.done.wait()
        return call.result()
    }

    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .waiting else { return false }
        phase = .started
        return true
    }

    private func finish(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
        done.signal()
    }

    private func abandonIfWaiting() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .waiting else { return false }
        phase = .abandoned
        return true
    }

    private func result() -> Value? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// 按查询分派：正在播放的三个查询给原来的提供者，待播清单的七个给 `QueueAgentProvider`。
final class AgentLinkRouter: AgentLinkQueryProvider {
    private let nowPlaying: AgentLinkQueryProvider
    private let queue: AgentLinkQueryProvider

    init(nowPlaying: AgentLinkQueryProvider, queue: AgentLinkQueryProvider) {
        self.nowPlaying = nowPlaying
        self.queue = queue
    }

    func answer(_ request: AgentLinkRequest) -> AgentLinkReply {
        request.query.isQueueQuery ? queue.answer(request) : nowPlaying.answer(request)
    }
}

/// 应用端回答待播清单的七个查询。参数先在后台线程校验，读写 `QueueStore` 回主线程做，
/// 解析字幕文件放回后台线程。工具级错误放在结果里（带 `error` 键），由桥接进程标成 `isError`。
final class QueueAgentProvider: AgentLinkQueryProvider {
    typealias Failure = QueueAgentQuery.Failure

    /// 从播放器读回的位置，用来确认 `seek_to` 跳到了。
    struct PlaybackReadback {
        let seconds: Double
        let isPlaying: Bool
    }

    static let mainThreadTimeout: TimeInterval = 2
    static let seekConfirmTimeout: TimeInterval = 5
    static let seekTolerance: Double = 1.5
    static let busyWriteMessage = "seesee 正忙，没来得及处理，这次什么都没改，稍后再试"

    /// 应用的 `QueueStore` 由 SwiftUI 建好后在主线程接上；只在主线程读写。接上之前的查询回答「seesee 正在启动」。
    weak var store: QueueStore?
    private let mainThreadTimeout: TimeInterval
    private let seekConfirmTimeout: TimeInterval
    private let readPlayback: @MainActor (UUID) -> PlaybackReadback?

    init(
        store: QueueStore?,
        mainThreadTimeout: TimeInterval = QueueAgentProvider.mainThreadTimeout,
        seekConfirmTimeout: TimeInterval = QueueAgentProvider.seekConfirmTimeout,
        readPlayback: @escaping @MainActor (UUID) -> PlaybackReadback?
    ) {
        self.store = store
        self.mainThreadTimeout = mainThreadTimeout
        self.seekConfirmTimeout = seekConfirmTimeout
        self.readPlayback = readPlayback
    }

    func answer(_ request: AgentLinkRequest) -> AgentLinkReply {
        let arguments = request.arguments
        do {
            switch request.query {
            case .listQueue:
                return try listQueue(arguments)
            case .moveItems:
                return try moveItems(arguments)
            case .addLinks:
                return try addLinks(arguments)
            case .searchSubtitles:
                return try searchSubtitles(arguments)
            case .seekTo:
                return try seek(arguments)
            case .writeChapters:
                return try writeChapters(arguments)
            case .readSubtitles:
                return try readSubtitles(arguments)
            case .writeSubtitleTranslations:
                return try writeSubtitleTranslations(arguments)
            case .restoreInitialTranslation:
                return try restoreInitialTranslation(arguments)
            case .nowPlaying, .subtitles, .frame:
                return .failure(code: AgentLinkReply.badRequest, message: nil)
            }
        } catch let failure as Failure {
            return .success(failure.payload)
        } catch let failure as SubtitleVersionStore.Failure {
            return .success(["error": failure.code, "message": failure.message])
        } catch let busy as Busy {
            return .failure(code: AgentLinkReply.busy, message: busy.message)
        } catch {
            return .failure(code: AgentLinkReply.badRequest, message: "\(error)")
        }
    }

    // MARK: - 七个查询

    private func listQueue(_ arguments: AgentLinkArguments) throws -> AgentLinkReply {
        let payload = try onMain(writes: false) { store -> [String: Any] in
            var payload = try QueueAgentQuery.listQueue(
                store.queueItems + store.archivedItems,
                arguments: arguments,
                previewPlayable: store.isPreviewPlayable
            )
            if store.upgradeBackupFailed {
                payload["message"] = Failure.backupFailed.message
            } else if store.queueWriteFailed {
                payload["message"] = Failure.writeFailed.message
            } else if !store.acceptsAgentWrites {
                payload["message"] = "seesee 读不出待播清单文件 queue.json，清单暂时是空的"
            }
            return payload
        }
        return .success(payload)
    }

    private func moveItems(_ arguments: AgentLinkArguments) throws -> AgentLinkReply {
        let parsed = try QueueAgentQuery.moveTarget(arguments)
        let payload = try onMain(writes: true) { store -> [String: Any] in
            let (ids, missing) = QueueAgentQuery.itemIDs(parsed.ids) { store.item(with: $0) != nil }
            guard missing.isEmpty else { throw Failure.notFound(missing) }
            let before = store.moveItems(ids, to: parsed.target)
            return QueueAgentQuery.moveResult(target: parsed.target, before: before, requested: ids, after: store.item(with:))
        }
        return .success(payload)
    }

    private func addLinks(_ arguments: AgentLinkArguments) throws -> AgentLinkReply {
        let decisions = try QueueAgentQuery.linkDecisions(arguments)
        let payload = try onMain(writes: true) { store -> [String: Any] in
            var accepted: [URL] = []
            var rejected: [[String: Any]] = []
            for decision in decisions {
                switch decision {
                case .accepted(_, let url): accepted.append(url)
                case .rejected(let input, let reason): rejected.append(QueueAgentQuery.rejectedObject(input: input, reason: reason))
                }
            }
            let dispositions = accepted.isEmpty ? [] : store.addBatch(accepted, activatesApp: false)
            var added: [[String: Any]] = []
            var existing: [[String: Any]] = []
            for disposition in dispositions {
                switch disposition {
                case .added(let id):
                    guard let item = store.item(with: id) else { continue }
                    added.append(["url": item.urlString, "itemID": id.uuidString, "status": item.status.rawValue])
                case .existing(let id):
                    guard let item = store.item(with: id) else { continue }
                    existing.append([
                        "url": item.urlString,
                        "itemID": id.uuidString,
                        "status": item.status.rawValue,
                        "title": item.title
                    ])
                }
            }
            var payload: [String: Any] = ["added": added, "existing": existing, "rejected": rejected]
            if accepted.isEmpty {
                payload.merge(Failure.invalid("一个链接都没加：全部被拒收，原因见 rejected").payload) { _, new in new }
            }
            return payload
        }
        return .success(payload)
    }

    private func searchSubtitles(_ arguments: AgentLinkArguments) throws -> AgentLinkReply {
        let parsed = try QueueAgentQuery.searchArguments(arguments)
        let sources = try onMain(writes: false) { store -> [QueueAgentQuery.SubtitleSource] in
            var ordered = store.queueItems + store.archivedItems
            if let raw = parsed.ids {
                let (ids, missing) = QueueAgentQuery.itemIDs(raw) { store.item(with: $0) != nil }
                guard missing.isEmpty else { throw Failure.notFound(missing) }
                let wanted = Set(ids)
                ordered = ordered.filter { wanted.contains($0.id) }
            }
            if let statuses = parsed.statuses {
                ordered = ordered.filter { statuses.contains($0.status) }
            }
            return ordered.map { QueueAgentQuery.SubtitleSource(item: $0, path: $0.subtitleFilePath) }
        }
        return .success(QueueAgentQuery.search(sources, query: parsed.query, limit: parsed.limit))
    }

    private func seek(_ arguments: AgentLinkArguments) throws -> AgentLinkReply {
        let parsed = try QueueAgentQuery.seekArguments(arguments)
        let opened = try onMain(writes: true) { store -> (item: WatchItem, requestID: UUID) in
            let (ids, missing) = QueueAgentQuery.itemIDs([parsed.itemID]) { store.item(with: $0) != nil }
            guard missing.isEmpty, let id = ids.first, let item = store.item(with: id) else {
                throw Failure.notFound(missing.isEmpty ? [parsed.itemID] : missing)
            }
            if let duration = QueueAgentQuery.finitePositive(item.duration), parsed.seconds > duration {
                throw Failure(
                    code: Failure.outOfRange,
                    message: "\(parsed.seconds) 秒超出《\(item.title)》的时长 \(NowPlayingQuery.timecode(duration))（\(QueueAgentQuery.rounded(duration)) 秒）",
                    details: ["durationSeconds": QueueAgentQuery.rounded(duration)]
                )
            }
            let disconnected = store.isMediaFolderDisconnected && item.state == .ready
            guard !disconnected, store.playbackSource(for: item).url != nil else {
                throw Failure(
                    code: Failure.notPlayable,
                    message: QueueAgentQuery.notPlayableMessage(item, mediaFolderDisconnected: store.isMediaFolderDisconnected),
                    details: ["itemID": item.id.uuidString, "downloadState": item.state.rawValue]
                )
            }
            store.updatePlaybackPosition(parsed.seconds, for: item.id)
            let request = store.requestAgentSeek(to: parsed.seconds, play: parsed.play, for: item.id)
            return (item, request.id)
        }

        // 等详情视图打开、播放器跳过去，再从播放器读回实际位置。
        let deadline = Date().addingTimeInterval(seekConfirmTimeout)
        var readback: PlaybackReadback?
        repeat {
            Thread.sleep(forTimeInterval: 0.1)
            let itemID = opened.item.id
            let target = parsed.seconds
            let current = MainThreadCall<PlaybackReadback?>.run(timeout: mainThreadTimeout) { [readPlayback] in
                readPlayback(itemID)
            } ?? nil
            if let current, abs(current.seconds - target) <= Self.seekTolerance {
                readback = current
                break
            }
        } while Date() < deadline

        var payload: [String: Any] = [
            "itemID": opened.item.id.uuidString,
            "title": opened.item.title,
            "applied": readback != nil
        ]
        if let readback {
            payload["positionSeconds"] = QueueAgentQuery.rounded(readback.seconds)
            payload["position"] = NowPlayingQuery.timecode(readback.seconds)
            payload["playing"] = readback.isPlaying
        } else {
            payload["positionSeconds"] = QueueAgentQuery.rounded(parsed.seconds)
            payload["position"] = NowPlayingQuery.timecode(parsed.seconds)
            payload["playing"] = false
            payload["message"] = "视频已经在 seesee 里选中，播放器还没加载好；加载完成后会跳到 \(NowPlayingQuery.timecode(parsed.seconds))。seesee 的窗口关着时要先打开窗口。"
        }
        return .success(payload)
    }

    private func writeChapters(_ arguments: AgentLinkArguments) throws -> AgentLinkReply {
        let rawID = try QueueAgentQuery.singleItemID(arguments["item_id"])
        let payload = try onMain(writes: true) { store -> [String: Any] in
            let (ids, missing) = QueueAgentQuery.itemIDs([rawID]) { store.item(with: $0) != nil }
            guard missing.isEmpty, let id = ids.first, let item = store.item(with: id) else {
                throw Failure.notFound(missing.isEmpty ? [rawID] : missing)
            }
            guard !item.hasUserChapters else {
                throw Failure(
                    code: Failure.chaptersUserEdited,
                    message: "《\(item.title)》的章节被用户手动改过，不能覆盖，什么都没写",
                    details: ["itemID": item.id.uuidString]
                )
            }
            let chapters = try QueueAgentQuery.chapters(arguments, duration: item.duration)
            let replacedPrevious = item.agentChapters?.isEmpty == false
            store.replaceAgentChapters(chapters, for: id)
            let after = store.item(with: id) ?? item
            return [
                "itemID": id.uuidString,
                "title": after.title,
                "written": chapters.count,
                "replacedPrevious": replacedPrevious,
                "chapterSource": after.chapterSource.rawValue
            ]
        }
        return .success(payload)
    }

    private func readSubtitles(_ arguments: AgentLinkArguments) throws -> AgentLinkReply {
        let parsed = try QueueAgentQuery.readArguments(arguments)
        let source = try onMain(writes: false) { store -> QueueAgentQuery.SubtitleSource in
            let (ids, missing) = QueueAgentQuery.itemIDs([parsed.itemID]) { store.item(with: $0) != nil }
            guard missing.isEmpty, let id = ids.first, let item = store.item(with: id) else {
                throw Failure.notFound(missing.isEmpty ? [parsed.itemID] : missing)
            }
            return QueueAgentQuery.SubtitleSource(item: item, path: item.subtitleFilePath)
        }
        return .success(try QueueAgentQuery.readSubtitles(source, start: parsed.start, end: parsed.end, maxCues: parsed.maxCues, startIndex: parsed.startIndex))
    }

    private func writeSubtitleTranslations(_ arguments: AgentLinkArguments) throws -> AgentLinkReply {
        let parsed = try QueueAgentQuery.translationArguments(arguments)
        let payload = try onMain(writes: true) { store -> [String: Any] in
            let (ids, missing) = QueueAgentQuery.itemIDs([parsed.itemID]) { store.item(with: $0) != nil }
            guard missing.isEmpty, let id = ids.first else { throw Failure.notFound(missing) }
            let snapshot = try store.writeSubtitleTranslations(parsed.translations, revision: parsed.revision, for: id)
            return ["itemID": id.uuidString, "revision": snapshot.revision, "written": snapshot.cues.count, "translationSource": store.item(with: id)?.translationSource ?? NSNull()]
        }
        return .success(payload)
    }

    private func restoreInitialTranslation(_ arguments: AgentLinkArguments) throws -> AgentLinkReply {
        let itemID = try QueueAgentQuery.singleItemID(arguments["item_id"])
        let payload = try onMain(writes: true) { store -> [String: Any] in
            let (ids, missing) = QueueAgentQuery.itemIDs([itemID]) { store.item(with: $0) != nil }
            guard missing.isEmpty, let id = ids.first else { throw Failure.notFound(missing) }
            let snapshot = try store.restoreInitialTranslation(for: id)
            return ["itemID": id.uuidString, "revision": snapshot.revision, "translationSource": store.item(with: id)?.translationSource ?? NSNull()]
        }
        return .success(payload)
    }

    // MARK: - 主线程

    private struct Busy: Error {
        let message: String?
    }

    /// 回主线程执行 `body`。写操作先确认 queue.json 读得出来；主线程没空时抛 `Busy`，这时 `body` 没执行。
    private func onMain<T>(writes: Bool, _ body: @escaping @MainActor (QueueStore) throws -> T) throws -> T {
        let outcome = MainThreadCall<Result<T, Error>>.run(timeout: mainThreadTimeout) { [weak self] in
            guard let store = self?.store else {
                return .failure(Failure(code: "not_ready", message: "seesee 正在启动或退出，待播清单还没准备好，稍后再试"))
            }
            if writes, !store.prepareAgentWrites() {
                return .failure(store.upgradeBackupFailed ? Failure.backupFailed : (store.queueWriteFailed ? Failure.writeFailed : Failure.unreadable))
            }
            return Result {
                let result = try body(store)
                if writes, !store.flushPendingSaves() { throw Failure.writeFailed }
                return result
            }
        }
        guard let outcome else {
            throw Busy(message: writes ? Self.busyWriteMessage : nil)
        }
        return try outcome.get()
    }
}
