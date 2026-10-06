import AppKit
import AVFoundation
import Foundation

/// 视频详情视图登记「正在看的条目」。位置、播放状态、倍速不登记，每次查询时从活动播放器现取。
@MainActor
final class NowPlayingRegistry {
    static let shared = NowPlayingRegistry()

    private var current: (token: UUID, entry: NowPlayingEntry)?

    private init() {}

    func register(_ entry: NowPlayingEntry) -> UUID {
        let token = UUID()
        current = (token, entry)
        return token
    }

    /// 只更新自己登记的那一条；已被别的视图顶替时返回 false。
    @discardableResult
    func update(_ token: UUID, entry: NowPlayingEntry) -> Bool {
        guard current?.token == token else { return false }
        current = (token, entry)
        return true
    }

    /// 切换条目时新视图可能先登记、旧视图后注销；凭令牌只注销自己那条。
    func unregister(_ token: UUID) {
        guard current?.token == token else { return }
        current = nil
    }

    struct Snapshot {
        let context: NowPlayingContext?
        let asset: AVAsset?
        let time: CMTime
    }

    /// 查询时刻的快照：没有登记、没有活动播放器、播放器放的不是登记条目的文件时 context 为 nil。
    func snapshot() -> Snapshot {
        guard let player = PlaybackCommandCenter.shared.activeRoutePlayer else {
            return Snapshot(context: nil, asset: nil, time: .invalid)
        }
        let time = player.currentTime()
        let item = player.currentItem
        let duration = item?.duration.seconds
        let rate = player.rate != 0 ? Double(player.rate) : PlaybackRatePreference.load()
        let clock = NowPlayingClock(
            seconds: time.seconds,
            isPlaying: player.timeControlStatus != .paused,
            rate: rate,
            durationSeconds: duration
        )
        let context = NowPlayingQuery.context(
            entry: current?.entry,
            playerFileURL: (item?.asset as? AVURLAsset)?.url,
            clock: clock
        )
        return Snapshot(context: context, asset: item?.asset, time: time)
    }
}

/// 应用端回答套接字查询：回主线程读登记和播放器，取帧放后台并限时 5 秒。
final class NowPlayingAgentProvider: AgentLinkQueryProvider {
    /// 主线程这么久都没空时回答 busy，不让连接一直挂着。
    static let mainThreadTimeout: TimeInterval = 2

    private final class SnapshotBox {
        private let lock = NSLock()
        private var value: NowPlayingRegistry.Snapshot?
        func set(_ newValue: NowPlayingRegistry.Snapshot) {
            lock.lock(); value = newValue; lock.unlock()
        }
        func get() -> NowPlayingRegistry.Snapshot? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    func answer(_ request: AgentLinkRequest) -> AgentLinkReply {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SnapshotBox()
        Task { @MainActor in
            box.set(NowPlayingRegistry.shared.snapshot())
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.mainThreadTimeout) == .success, let snapshot = box.get() else {
            return .failure(code: AgentLinkReply.busy, message: nil)
        }
        return NowPlayingQuery.answer(request, context: snapshot.context) { width in
            guard let asset = snapshot.asset, snapshot.time.isValid else { return .failed }
            let time = snapshot.time
            return NowPlayingFrameCapture.run(timeout: NowPlayingFrameCapture.timeout) {
                NowPlayingFrameCapture.jpegBase64(asset: asset, time: time, maxWidth: width)
            }
        }
    }
}

extension NowPlayingFrameCapture {
    /// 从视频文件精确取一帧，缩到不超过 maxWidth，编成 JPEG 的 base64。
    static func jpegBase64(asset: AVAsset, time: CMTime, maxWidth: Double) -> String? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.82]
        ) else {
            return nil
        }
        return data.base64EncodedString()
    }
}
