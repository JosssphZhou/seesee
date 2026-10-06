import AppKit
import Foundation

/// 从真实 QueueStore 的启动、保存、重开和设置模型状态入口验证恢复；媒体与队列为隔离构造数据。
@main
struct TranscriptionRecoveryCheck {
    struct Failed: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failed(message: message) } }
    struct Fixture {
        let root: URL, media: URL, file: URL, original: URL
        let suite: String, id: UUID
        @MainActor func store() -> QueueStore {
            QueueStore(dataFile: file, mediaFolder: media, defaults: UserDefaults(suiteName: suite)!, mountedVolumeURLs: [])
        }
        func clean() { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        func row() throws -> [String: Any] { (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]])[0] }
    }
    static func fixture(error: String, original: Bool, retries: Int = 0) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/ss-rework-recovery-\(UUID().uuidString)")
        let media = root.appendingPathComponent("media"); try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let id = UUID(), source = media.appendingPathComponent("original.vtt"), file = root.appendingPathComponent("queue.json")
        try Data("WEBVTT\n\nNOTE seesee-sentence-blocks-v1\n\n1\n00:00:00.000 --> 00:00:02.000\nWelcome.\n".utf8).write(to: source)
        var row: [String: Any] = ["id": id.uuidString, "urlString": "https://example.invalid/recovery", "title": "失败恢复样本", "author": "", "addedAt": "2026-10-01T00:00:00Z", "state": "ready", "progress": 1, "progressLabel": "已下载", "subtitleFilePath": "", "transcriptionState": "failed", "transcriptionError": error, "transcriptionAutomaticRetryCount": retries]
        let movie = media.appendingPathComponent("fixture.mp4"); try Data("fixture media".utf8).write(to: movie); row["localFilePath"] = movie.path
        if original { row["originalSubtitlePath"] = source.path; row["subtitleFilePath"] = source.path; row["transcriptionLanguage"] = "en" }
        try JSONSerialization.data(withJSONObject: [row]).write(to: file)
        return Fixture(root: root, media: media, file: file, original: source, suite: "seesee.check.recovery.\(UUID().uuidString)", id: id)
    }
    @MainActor static func wait(_ store: QueueStore, id: UUID, state: String) async throws {
        for _ in 0..<200 {
            if store.item(with: id)?.transcriptionState == state { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failed(message: "等待\(state)失败，实际\(store.item(with: id)?.transcriptionState ?? "nil")：\(store.item(with: id)?.transcriptionError ?? "")")
    }
    @MainActor final class AvailableModels: TranscriptionModelBackend {
        func currentState() async -> TranscriptionModelState { .available }
        func requestDownload(progress: @escaping @MainActor (Double) -> Void) async throws { progress(1) }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard #available(macOS 26, *) else { print("transcription_recovery_check=未实测：需要macOS26"); return }
        let f = try fixture(error: "本机翻译语言包未安装，原文字幕已保留", original: true); defer { f.clean() }
        let original = try Data(contentsOf: f.original)
        let reopened = f.store(); reopened.startLocalTranscriptionQueue(); defer { reopened.stopLocalTranscriptionQueue() }
        try check(reopened.item(with: f.id)?.transcriptionState != "failed", "失败条目重开必须重新排队，不能永久failed")
        try await wait(reopened, id: f.id, state: "ready")
        try check(reopened.item(with: f.id)?.originalSubtitlePath == f.original.path && Data(contentsOf: f.original) == original, "恢复只补翻译，原文路径与字节不变")
        try check(reopened.item(with: f.id)?.translationSource == "apple" && reopened.flushPendingSaves(), "真实本机初译恢复并保存")
        let models = try fixture(error: "请先在设置页下载中英文语音模型", original: true); defer { models.clean() }
        let waiting = models.store(); defer { waiting.stopLocalTranscriptionQueue() }
        let status = TranscriptionModelStatus(backend: AvailableModels(), forcedState: nil)
        await status.refresh()
        try check(waiting.item(with: models.id)?.transcriptionState == "queued", "设置模型状态变可用必须通知队列重排资源失败")
        waiting.startLocalTranscriptionQueue(); try await wait(waiting, id: models.id, state: "ready")
        let generic = try fixture(error: "提取音频失败", original: false); defer { generic.clean() }
        for count in 1...3 {
            let retry = generic.store(); retry.startLocalTranscriptionQueue()
            try check(retry.item(with: generic.id)?.transcriptionState != "failed", "其他失败启动自动重试第\(count)次")
            try await wait(retry, id: generic.id, state: "failed")
            try check(retry.flushPendingSaves(), "失败和计数落盘")
            try check(try generic.row()["transcriptionAutomaticRetryCount"] as? Int == count, "自动重试次数必须持久化")
            retry.stopLocalTranscriptionQueue()
        }
        let capped = generic.store(); capped.startLocalTranscriptionQueue(); defer { capped.stopLocalTranscriptionQueue() }
        try check(capped.item(with: generic.id)?.transcriptionState == "failed", "超过3次不能自动循环")
        capped.retryLocalTranscription(for: generic.id)
        try check(capped.item(with: generic.id)?.transcriptionState != "failed", "公开重试接口必须能重新排队")
        try await wait(capped, id: generic.id, state: "failed")
        try check(capped.flushPendingSaves() && (try generic.row()["transcriptionAutomaticRetryCount"] as? Int) == 0, "手动重试恢复自动重试额度")
        print("transcription_recovery_check=passed：旧资源失败重开完成、模型可用通知、只补初译、持久化3次上限和公开重试通过")
    }
}
