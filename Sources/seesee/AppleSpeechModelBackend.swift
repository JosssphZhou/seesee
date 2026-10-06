import Foundation
import Speech

/// 设置页直接接现有 TranscriptionModelBackend；一次请求中英文，权重完全由系统管理。
@MainActor
final class AppleSpeechModelBackend: TranscriptionModelBackend {
    struct Failed: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private var installationProgress: Progress?

    func currentState() async -> TranscriptionModelState {
        guard #available(macOS 26, *) else { return .unsupportedSystem }
        guard SpeechTranscriber.isAvailable else { return .failed }
        // installedLocales 是能实际转写的已安装语言；部分系统的模块状态仍报告 supported。
        if await AppleSpeechAssets.areInstalled() { return .available }
        do {
            let modules = try await AppleSpeechAssets.modules()
            switch await AssetInventory.status(forModules: modules) {
            case .installed: return .available
            case .downloading: return .downloading(fraction: installationProgress?.fractionCompleted ?? 0)
            case .supported: return .notInstalled
            case .unsupported: return .failed
            @unknown default: return .failed
            }
        } catch { return .failed }
    }

    func requestDownload(progress: @escaping @MainActor (Double) -> Void) async throws {
        guard #available(macOS 26, *) else { throw Failed(message: "需要 macOS 26 或更新版本") }
        let modules = try await AppleSpeechAssets.modules()
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            guard await AppleSpeechAssets.areInstalled() else {
                throw Failed(message: "系统无法请求中英文语音模型，请稍后重试")
            }
            progress(1)
            return
        }
        installationProgress = request.progress
        let polling = Task { @MainActor in
            while !Task.isCancelled {
                progress(min(1, max(0, request.progress.fractionCompleted)))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { polling.cancel(); installationProgress = nil }
        try await request.downloadAndInstall()
        guard await AppleSpeechAssets.areInstalled() else {
            throw Failed(message: "中英文语音模型尚未全部装好，请重试")
        }
        progress(1)
    }
}

@available(macOS 26, *)
enum AppleSpeechAssets {
    static func locales() async throws -> [Locale] {
        var locales: [Locale] = []
        for identifier in ["en_US", "zh_CN"] {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
                throw AppleSpeechModelBackend.Failed(message: "系统不支持所需的中英文语音模型")
            }
            locales.append(locale)
        }
        return locales
    }
    static func areInstalled() async -> Bool {
        guard let required = try? await locales() else { return false }
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
        return required.allSatisfy { installed.contains($0.identifier) }
    }
    static func modules() async throws -> [SpeechTranscriber] {
        try await locales().map { SpeechTranscriber(locale: $0, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence]) }
    }
}
