enum SubtitleDispatchSurface: Equatable {
    case primary
    case fullscreen
    case floating
}

enum SubtitleDispatchPolicy {
    /// 与播放器 seek 共用的时间基。CMTime(seconds:preferredTimescale:) 按该分母截断。
    static let seekTimescale: Int32 = 600

    /// 字幕只发给当前实际承载画面的表面。
    static func destination(
        isFloatingActive: Bool,
        isFullscreen: Bool
    ) -> SubtitleDispatchSurface {
        if isFloatingActive { return .floating }
        if isFullscreen { return .fullscreen }
        return .primary
    }

    /// 非目标表面必须清空，避免主窗黑底残留字幕。
    static func shouldReceive(
        _ surface: SubtitleDispatchSurface,
        destination: SubtitleDispatchSurface
    ) -> Bool {
        surface == destination
    }

    /// 暂停态 seek 按目标时间立刻重发；播放器时钟可能尚未跳到目标点。
    static func presentationTime(afterSeekTo target: Double, playerTime: Double) -> Double {
        visibleTime(pendingSeekTime: target.isFinite ? target : nil, playerTime: playerTime)
    }

    /// seek 进行中继续按目标时间呈现，避免 SwiftUI 刷新用尚未更新的时钟写回旧句。
    static func visibleTime(pendingSeekTime: Double?, playerTime: Double) -> Double {
        if let pendingSeekTime, pendingSeekTime.isFinite { return max(0, pendingSeekTime) }
        if playerTime.isFinite { return max(0, playerTime) }
        return 0
    }

    /// 句首跳转向句内取整：把秒数换成 600 时间基时向上取整，避免截断到句首前 1 毫秒。
    static func quantizedSeekTicks(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        if seconds <= 0 { return 0 }
        return Int64((seconds * Double(seekTimescale)).rounded(.up))
    }

    static func quantizedSeekTime(_ seconds: Double) -> Double {
        Double(quantizedSeekTicks(seconds)) / Double(seekTimescale)
    }
}

/// 跟踪进行中的 seek：只有最新请求且 finished 为真才提交，过期回调直接丢弃。
struct SubtitleSeekSession: Equatable {
    private(set) var latestID: UInt64 = 0
    private(set) var pendingTime: Double?

    static func shouldCommit(callbackID: UInt64, latestID: UInt64, finished: Bool) -> Bool {
        finished && callbackID == latestID
    }

    mutating func issue(time: Double) -> UInt64 {
        latestID += 1
        pendingTime = time
        return latestID
    }

    mutating func invalidate() {
        latestID += 1
        pendingTime = nil
    }

    mutating func complete(id: UInt64, finished: Bool) -> Double? {
        guard Self.shouldCommit(callbackID: id, latestID: latestID, finished: finished) else {
            return nil
        }
        let time = pendingTime
        pendingTime = nil
        return time
    }
}
