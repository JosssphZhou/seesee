import Combine
import Foundation

/// 设置页「转写模型」一行的五种状态。转写用苹果自带的语音识别，语音模型由系统管理，
/// 应用只能请求系统下载，所以没有占用空间、删除和取消。
enum TranscriptionModelState: Equatable {
    case notInstalled
    /// 0...1。
    case downloading(fraction: Double)
    /// 中文和英文语音模型都装好了。
    case available
    case failed
    /// 系统低于 macOS 26，没有 SpeechTranscriber。
    case unsupportedSystem
}

/// 转写模型的后端：查状态、请求系统下载中文和英文语音模型。
/// 默认使用 AppleSpeechModelBackend，状态和下载均由系统语音资产接口提供。
@MainActor
protocol TranscriptionModelBackend: AnyObject {
    func currentState() async -> TranscriptionModelState
    /// 一次请求中文和英文两种语音模型；进度 0...1 经回调报告，失败抛错。
    func requestDownload(progress: @escaping @MainActor (Double) -> Void) async throws
}

/// 后端合入前的占位：一直是未安装，下载请求什么也不做。
@MainActor
final class PlaceholderTranscriptionModelBackend: TranscriptionModelBackend {
    func currentState() async -> TranscriptionModelState { .notInstalled }
    func requestDownload(progress: @escaping @MainActor (Double) -> Void) async throws {}
}

enum TranscriptionModelSupport {
    static let minimumMajorVersion = 26

    static func isSystemSupported(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        version.majorVersion >= minimumMajorVersion
    }
}

/// 调试用：`--transcription-model-state <状态>` 强制设置页显示某一种状态，只在这次启动有效，不写偏好设置。
/// 状态写 not-installed、downloading:0.38、available、failed、unsupported。
enum TranscriptionModelLaunchArguments {
    static let flag = "--transcription-model-state"

    static func forcedState(from arguments: [String] = CommandLine.arguments) -> TranscriptionModelState? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return parse(arguments[index + 1])
    }

    static func parse(_ raw: String) -> TranscriptionModelState? {
        switch raw {
        case "not-installed": return .notInstalled
        case "available": return .available
        case "failed": return .failed
        case "unsupported": return .unsupportedSystem
        default:
            guard raw.hasPrefix("downloading:"),
                  let fraction = Double(raw.dropFirst("downloading:".count)) else { return nil }
            return .downloading(fraction: min(max(fraction, 0), 1))
        }
    }
}

/// 设置页读的转写模型状态。系统版本不够时不问后端，直接是 unsupportedSystem。
@MainActor
final class TranscriptionModelStatus: ObservableObject {
    static let assetsAvailableNotification = Notification.Name("ai.openmy.seesee.transcription-assets-available")
    @Published private(set) var state: TranscriptionModelState
    private let backend: TranscriptionModelBackend
    private let forcedState: TranscriptionModelState?
    private var downloadTask: Task<Void, Never>?

    init(
        backend: TranscriptionModelBackend? = nil,
        systemSupported: Bool = TranscriptionModelSupport.isSystemSupported(),
        forcedState: TranscriptionModelState? = TranscriptionModelLaunchArguments.forcedState()
    ) {
        self.backend = backend ?? AppleSpeechModelBackend()
        self.forcedState = forcedState ?? (systemSupported ? nil : .unsupportedSystem)
        state = self.forcedState ?? .notInstalled
    }

    func refresh() async {
        guard forcedState == nil, downloadTask == nil else { return }
        updateState(await backend.currentState())
    }

    /// 下载和重试都走这里。
    func download() {
        guard forcedState == nil, downloadTask == nil else { return }
        switch state {
        case .notInstalled, .failed: break
        default: return
        }
        downloadTask = Task { [weak self, backend] in
            do {
                try await backend.requestDownload { fraction in
                    self?.state = .downloading(fraction: min(max(fraction, 0), 1))
                }
                let state = await backend.currentState()
                self?.updateState(state)
            } catch {
                self?.state = .failed
            }
            self?.downloadTask = nil
        }
    }

    private func updateState(_ newState: TranscriptionModelState) {
        let becameAvailable = state != .available && newState == .available
        state = newState
        if becameAvailable { NotificationCenter.default.post(name: Self.assetsAvailableNotification, object: self) }
    }
}
