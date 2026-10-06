import Combine
import Foundation
import os.log
import SwiftUI
#if canImport(Translation)
import Translation
#endif

private let titleTranslationLog = OSLog(subsystem: "ai.openmy.seesee", category: "title-translation")

/// 用 Apple 翻译框架在本机把标题翻成简体中文。不联网、不用密钥；翻不了时返回 nil，不报错、不提示。
///
/// 按系统版本分支：
/// - macOS 26.4 起：直接建 `.highFidelity` 会话，`isReady` 为真就翻（开着 Apple 智能时不用下载语言）。
/// - macOS 26.0 起：直接建普通会话，语言包已装就翻。
/// - macOS 15 起：会话只能从视图上的 `.translationTask` 拿，交给主窗口上的 `TitleTranslationHost` 翻。
///   语言包没装时，在主窗口上弹一次系统标准的下载提示；弹过以后不论同意与否都不再弹。
/// - macOS 13、14：没有可用的接口，不翻。
/// `Translation.framework` 是弱链接，旧系统上不会因为找不到它而启动失败。
@MainActor
final class OnDeviceTitleTranslator: ObservableObject {
    static let shared = OnDeviceTitleTranslator()
    static let targetLanguage = "zh-Hans"
    /// 偏好设置里记着「已经弹过下载提示」。
    static let downloadPromptShownKey = "TitleTranslationDownloadPromptShown"

    /// 主窗口上的 `.translationTask` 要处理的一批请求。
    struct HostRequest {
        let text: String
        let source: String
        /// 语言包没装时可以弹系统下载提示。整个应用只有第一个这样的请求为 true。
        let allowsDownloadPrompt: Bool
        let continuation: CheckedContinuation<String?, Never>
    }

    /// 主窗口要为哪种源语言挂会话；nil 时不挂。`hostGeneration` 每来一批新请求加一，让会话重新跑一次。
    @Published private(set) var hostSource: String?
    @Published private(set) var hostGeneration = 0
    private var hostRequests: [HostRequest] = []
    /// 主窗口的会话正在逐条翻。这时新来的请求直接排进去，不让会话重启（重启会取消正在翻的那条）。
    private var isServing = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `allowsDownloadPrompt` 为 false 时语言包没装就直接返回 nil，不弹下载提示（旧条目补翻用）。
    func translate(_ text: String, from source: String, allowsDownloadPrompt: Bool = true) async -> String? {
        guard !text.isEmpty else { return nil }
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else { return nil }
        let sourceLanguage = Locale.Language(identifier: source)
        let target = Locale.Language(identifier: Self.targetLanguage)
        if #available(macOS 26.4, *) {
            let session = TranslationSession(installedSource: sourceLanguage, target: target, preferredStrategy: .highFidelity)
            if await session.isReady, let translated = await Self.run(session, text) {
                os_log("translated source=%{public}@ path=highFidelity", log: titleTranslationLog, type: .default, source)
                return translated
            }
        }
        if #available(macOS 26.0, *) {
            let session = TranslationSession(installedSource: sourceLanguage, target: target)
            if await session.isReady, let translated = await Self.run(session, text) {
                os_log("translated source=%{public}@ path=installed", log: titleTranslationLog, type: .default, source)
                return translated
            }
        }
        let status = await LanguageAvailability().status(from: sourceLanguage, to: target)
        switch status {
        case .installed:
            return await translateOnMainWindow(text, source: source, allowsDownloadPrompt: false)
        case .supported:
            // 语言包没装：只弹一次系统下载提示。提示还在处理时，后来的请求排在它后面，下好了一起翻。
            guard allowsDownloadPrompt else {
                os_log("skipped source=%{public}@ reason=notInstalledNoPrompt", log: titleTranslationLog, type: .default, source)
                return nil
            }
            let mayPrompt = !defaults.bool(forKey: Self.downloadPromptShownKey)
            guard mayPrompt || !hostRequests.isEmpty || hostSource != nil else {
                os_log("skipped source=%{public}@ reason=notInstalled", log: titleTranslationLog, type: .default, source)
                return nil
            }
            if mayPrompt { defaults.set(true, forKey: Self.downloadPromptShownKey) }
            return await translateOnMainWindow(text, source: source, allowsDownloadPrompt: mayPrompt)
        case .unsupported:
            os_log("skipped source=%{public}@ reason=unsupported", log: titleTranslationLog, type: .default, source)
            return nil
        @unknown default:
            return nil
        }
        #else
        return nil
        #endif
    }

    private func translateOnMainWindow(_ text: String, source: String, allowsDownloadPrompt: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            hostRequests.append(HostRequest(
                text: text,
                source: source,
                allowsDownloadPrompt: allowsDownloadPrompt,
                continuation: continuation
            ))
            guard !isServing else { return }
            hostSource = source
            hostGeneration += 1
        }
    }

    private func nextHostRequest(for source: String) -> HostRequest? {
        guard let index = hostRequests.firstIndex(where: { $0.source == source }) else { return nil }
        return hostRequests.remove(at: index)
    }

    /// 一种源语言的请求翻完了：还有别的语言就让主窗口换一个会话，没有就不再挂会话。
    private func finishServing() {
        isServing = false
        if let next = hostRequests.first {
            hostSource = next.source
            hostGeneration += 1
        } else {
            hostSource = nil
        }
    }

    #if canImport(Translation)
    /// 主窗口上的 `.translationTask` 交来的会话。只在这个闭包里用它，视图消失后不再碰。
    @available(macOS 15.0, *)
    func serve(_ session: TranslationSession, source: String) async {
        let sourceLanguage = Locale.Language(identifier: source)
        let target = Locale.Language(identifier: Self.targetLanguage)
        isServing = true
        defer { finishServing() }
        while let request = nextHostRequest(for: source) {
            let status = await LanguageAvailability().status(from: sourceLanguage, to: target)
            if status == .supported, request.allowsDownloadPrompt {
                do {
                    // 系统在主窗口上弹标准的下载提示。用户拒绝或关掉时抛错，以后不再弹。
                    try await session.prepareTranslation()
                    os_log("language download accepted source=%{public}@", log: titleTranslationLog, type: .default, source)
                } catch {
                    os_log("language download declined source=%{public}@", log: titleTranslationLog, type: .default, source)
                    request.continuation.resume(returning: nil)
                    continue
                }
            } else if status != .installed {
                request.continuation.resume(returning: nil)
                continue
            }
            let translated = await Self.run(session, request.text)
            os_log("translated source=%{public}@ path=mainWindow ok=%{public}@", log: titleTranslationLog, type: .default,
                   source, translated == nil ? "no" : "yes")
            request.continuation.resume(returning: translated)
        }
    }

    @available(macOS 15.0, *)
    private static func run(_ session: TranslationSession, _ text: String) async -> String? {
        guard let response = try? await session.translate(text) else { return nil }
        return VideoTitleText.nonEmpty(response.targetText)
    }
    #endif
}

/// 挂在主窗口内容上：本机翻译要用 `.translationTask` 的会话时（macOS 15 到 26.3，或者要弹下载提示），
/// 由这里提供。主窗口不在时不挂，请求等主窗口出现再翻，不会从看不见的窗口弹下载提示。
struct TitleTranslationHost: ViewModifier {
    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            content.modifier(TitleTranslationTaskModifier(translator: .shared))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct TitleTranslationTaskModifier: ViewModifier {
    @ObservedObject var translator: OnDeviceTitleTranslator
    @State private var configuration: TranslationSession.Configuration?
    @State private var source: String?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                guard let source else { return }
                await translator.serve(session, source: source)
            }
            .onAppear(perform: refresh)
            .onChange(of: translator.hostGeneration) { refresh() }
    }

    private func refresh() {
        guard let hostSource = translator.hostSource else { return }
        if hostSource == source, configuration != nil {
            configuration?.invalidate()
        } else {
            source = hostSource
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: hostSource),
                target: Locale.Language(identifier: OnDeviceTitleTranslator.targetLanguage)
            )
        }
    }
}
#endif
