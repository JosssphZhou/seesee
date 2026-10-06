import AppKit
import Foundation

/// 生产串行元数据查询和QueueStore，假yt-dlp不联网。8秒是真实进程运行时间。
@main
struct SubtitleMetadataRecoveryCheck {
    struct Failed: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failed(message: message) } }
    struct Fixture {
        let root: URL, media: URL, file: URL
        let suite: String
        @MainActor func store() -> QueueStore {
            QueueStore(dataFile: file, mediaFolder: media, defaults: UserDefaults(suiteName: suite)!, mountedVolumeURLs: [])
        }
        func clean() { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        func rows() throws -> [[String: Any]] { try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]] }
    }
    static func fixture(count: Int, videoID: String? = nil) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/ss-metadata-recovery-\(UUID().uuidString)")
        let media = root.appendingPathComponent("media"); try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("queue.json")
        var rows: [[String: Any]] = []
        for number in 1...count {
            let id = UUID(), movie = media.appendingPathComponent("\(id.uuidString).mp4"), en = media.appendingPathComponent("\(id.uuidString).en.srt")
            try Data("fixture movie".utf8).write(to: movie)
            try Data("1\n00:00:00,000 --> 00:00:02,000\nWelcome.\n".utf8).write(to: en)
            try Data("1\n00:00:00,000 --> 00:00:02,000\n欢迎。\n".utf8).write(to: media.appendingPathComponent("\(id.uuidString).zh-Hans.srt"))
            let code = videoID ?? String(format: "Batch%06d", number)
            rows.append(["id": id.uuidString, "urlString": "https://www.youtube.com/watch?v=\(code)", "title": "元数据恢复检查", "author": "", "addedAt": "2026-10-01T00:00:00Z", "state": "ready", "progress": 1, "progressLabel": "已下载", "chapters": [], "localFilePath": movie.path, "subtitleFilePath": en.path])
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: file)
        return Fixture(root: root, media: media, file: file, suite: "seesee.check.metadata.\(UUID().uuidString)")
    }
    @MainActor static func wait(_ predicate: () -> Bool, seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failed(message: "等待元数据检查超时")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let tools = Bundle.main.resourceURL!.appendingPathComponent("Tools")
        try check(!FileManager.default.fileExists(atPath: tools.path), "检查工具目录必须属于本轮空目录")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        let allow = tools.appendingPathComponent("allow-retry"), calls = tools.appendingPathComponent("calls.txt")
        let script = """
        #!/bin/bash
        for argument in "$@"; do url="$argument"; done
        printf '%s\\n' "$url" >> '\(calls.path)'
        if [[ "$url" == *Batch* ]]; then /bin/sleep 8; fi
        if [[ "$url" == *Empty* ]]; then exit 0; fi
        if [[ "$url" == *Retry* ]] && [[ ! -f '\(allow.path)' ]]; then exit 1; fi
        printf 'WL_META\\t"元数据检查"\\t"检查"\\t60\\t[]\\tnull\\t"en"\\t{"en":[]}\\t{"zh-Hans":[]}\\n'
        """
        let executable = tools.appendingPathComponent("yt-dlp")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if !CommandLine.arguments.contains("retry-only") {
            let f = try fixture(count: 6); defer { f.clean() }
            let queue = f.store(); defer { queue.stopLocalTranscriptionQueue() }
            let started = Date(); queue.startLocalTranscriptionQueue()
            try await wait({ queue.items.allSatisfy { $0.translationSource != nil } }, seconds: 57)
            try check(queue.items.allSatisfy { $0.translationSource == "youtube_auto" && $0.translationPolishable }, "六条各查8秒的旧片不能因排队超过30秒而误记人工")
            try check(queue.items.allSatisfy { item in
                guard let file = item.subtitleFileURL, let track = VideoSubtitleTrack(contentsOf: file) else { return false }
                return track.cues.allSatisfy(\.isSentenceBlock)
            }, "中文下载轨仍按统一句块显示")
            try check(queue.flushPendingSaves() && f.store().items.allSatisfy { $0.translationSource == "youtube_auto" }, "六条机器来源真正保存")
            print(String(format: "queued_metadata=passed count=6 per_process=8s elapsed=%.3fs all=youtube_auto", Date().timeIntervalSince(started)))
            fflush(stdout)
            if CommandLine.arguments.contains("batch-only") { return }
        }
        let failed = try fixture(count: 1, videoID: "Retry000001"); defer { failed.clean() }
        let id = UUID(uuidString: try failed.rows()[0]["id"] as! String)!
        for attempt in 1...3 {
            let queue = failed.store(); queue.startLocalTranscriptionQueue(); defer { queue.stopLocalTranscriptionQueue() }
            try await wait { queue.item(with: id)?.translationSource != nil || ((try? failed.rows()[0]["subtitleMetadataFailureCount"] as? Int) ?? 0) == attempt }
            try check(queue.flushPendingSaves(), "模拟退出时保存，不能在内存更新后直接断言延迟写盘内容")
            try check((try failed.rows()[0]["subtitleMetadataFailureCount"] as? Int) == attempt, "查询失败次数必须持久化，每次启动只查一次")
            if attempt < 3 {
                try check(queue.item(with: id)?.translationSource == nil && queue.item(with: id)?.initialSubtitlePath == nil, "前两次失败不能把未知来源永久落成author")
            } else {
                try await wait { queue.item(with: id)?.translationSource == "author" }
                try check(queue.flushPendingSaves() && !queue.item(with: id)!.translationPolishable, "第三次失败按人工保守处理")
            }
        }
        let callsBefore = try String(contentsOf: calls, encoding: .utf8)
        let stopped = failed.store(); stopped.startLocalTranscriptionQueue(); stopped.stopLocalTranscriptionQueue()
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(try String(contentsOf: calls, encoding: .utf8) == callsBefore, "上限之后重开不能无限查询")
        let recovered = try fixture(count: 1, videoID: "Retry000002"); defer { recovered.clean() }
        let recoveringID = UUID(uuidString: try recovered.rows()[0]["id"] as! String)!
        let first = recovered.store(); first.startLocalTranscriptionQueue()
        try await wait { ((try? recovered.rows()[0]["subtitleMetadataFailureCount"] as? Int) ?? 0) == 1 }
        first.stopLocalTranscriptionQueue()
        try Data().write(to: allow)
        let reopened = recovered.store(); reopened.startLocalTranscriptionQueue(); defer { reopened.stopLocalTranscriptionQueue() }
        try await wait { reopened.item(with: recoveringID)?.translationSource == "youtube_auto" }
        try check(reopened.flushPendingSaves(), "失败后下次启动可恢复机器来源")
        try check((try recovered.rows()[0]["subtitleMetadataFailureCount"] as? Int) == 0, "成功查询清除失败计数")
        let empty = try fixture(count: 1, videoID: "Empty000001"); defer { empty.clean() }
        let emptyQueue = empty.store(); emptyQueue.startLocalTranscriptionQueue(); defer { emptyQueue.stopLocalTranscriptionQueue() }
        try await wait { ((try? empty.rows()[0]["subtitleMetadataFailureCount"] as? Int) ?? 0) == 1 }
        try check(emptyQueue.items[0].translationSource == nil, "工具正常退出却没有元数据也须作为查询失败重查")
        print("metadata_retry=passed：失败不立即落人工、跨启动3次上限、次次只查一次、再次成功可恢复机器来源")
    }
}
