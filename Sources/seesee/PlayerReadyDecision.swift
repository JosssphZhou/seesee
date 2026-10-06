import Foundation

enum PlayerReadyDecision {
    enum LoadSignal: Equatable {
        case none
        case load
        case unload
    }

    /// 右侧播放器当前该播的片源：下载中的在线预览、下完的本地文件，或者都没有（显示等待画面）。
    enum Source: Equatable {
        case preview(URL)
        case localFile(URL)
        case none

        var url: URL? {
            switch self {
            case .preview(let url), .localFile(let url): return url
            case .none: return nil
            }
        }

        var isPreview: Bool {
            if case .preview = self { return true }
            return false
        }
    }

    static func isPlayable(state: DownloadState, localFileExists: Bool) -> Bool {
        state == .ready && localFileExists
    }

    /// 下完一律播本地文件；没下完、也没失败时有预览流就播预览。
    /// 排队状态也算没下完：重试倒计时、等网络、低电量暂停时预览继续，断网时播放器停在缓冲。
    /// `localFileURL` 只在已下完时才取，因为取它要查磁盘，队列每一行都会问一次。
    static func source(
        state: DownloadState,
        previewURL: URL?,
        localFileURL: @autoclosure () -> URL?
    ) -> Source {
        switch state {
        case .ready:
            return localFileURL().map(Source.localFile) ?? .none
        case .downloading, .queued:
            return previewURL.map(Source.preview) ?? .none
        case .failed:
            return .none
        }
    }

    static func loadSignal(previousPlayable: Bool, currentPlayable: Bool) -> LoadSignal {
        switch (previousPlayable, currentPlayable) {
        case (false, true):
            return .load
        case (true, false):
            return .unload
        default:
            return .none
        }
    }
}
