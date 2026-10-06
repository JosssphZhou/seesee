import AppKit
import Darwin
import Foundation

/// 构造旧片库、新增链接及假yt-dlp，从真实队列/下载入口检查范围、优先级和30秒截止。
@main
struct QueueTranscriptionScopeCheck {
    struct Failed: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failed(message: message) } }
    struct Fixture {
        let root: URL, media: URL, file: URL
        let suite: String
        @MainActor func store(network: NetworkMonitor? = nil) -> QueueStore { QueueStore(dataFile: file, mediaFolder: media, defaults: UserDefaults(suiteName: suite)!, mountedVolumeURLs: [], networkMonitor: network) }
        func clean() { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    }
    static func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/ss-library-scope-\(UUID().uuidString)")
        let media = root.appendingPathComponent("media"); try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        return Fixture(root: root, media: media, file: root.appendingPathComponent("queue.json"), suite: "seesee.check.library-scope.\(UUID().uuidString)")
    }
    static func row(_ f: Fixture, id: UUID, status: String = "to_watch", subtitles: Bool = true, url: String = "https://example.invalid/library") throws -> [String: Any] {
        let movie = f.media.appendingPathComponent("\(id.uuidString).mp4"), en = f.media.appendingPathComponent("\(id.uuidString).en.srt")
        try Data("fixture video".utf8).write(to: movie)
        if subtitles { try Data("1\n00:00:00,000 --> 00:00:02,000\nWelcome.\n".utf8).write(to: en) }
        return ["id": id.uuidString, "urlString": url, "title": "隔离旧片库样本", "author": "", "addedAt": "2070-01-01T00:00:00Z", "state": "ready", "progress": 1, "progressLabel": "已下载", "watchStatus": status, "chapters": [], "duration": 60, "localFilePath": movie.path, "subtitleFilePath": subtitles ? en.path : ""]
    }
    @MainActor static func wait(_ predicate: () -> Bool, seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failed(message: "等待队列结果超时")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let base = Bundle.main.resourceURL!, tools = base.appendingPathComponent("Tools"), pidFile = base.appendingPathComponent("metadata-owned-pid.txt")
        try check(!FileManager.default.fileExists(atPath: tools.path), "测试工具目录必须是本轮空目录")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tools); try? FileManager.default.removeItem(at: pidFile) }
        let script = """
        #!/bin/bash
        for argument in "$@"; do url="$argument"; done
        if [[ "$url" == *Stall000001* ]]; then
          printf '%s' "$$" > '\(pidFile.path)'
          exec /bin/sleep 60
        fi
        paths=''; output=''
        while [ $# -gt 0 ]; do
          case "$1" in --paths) paths="$2";; --output) output="$2";; esac
          shift
        done
        printf 'WL_META\\t"字幕样本"\\t"检查"\\t60\\t[]\\tnull\\t"en"\\t{"en":[]}\\t{}\\n'
        if [ -n "$paths" ] && [ -n "$output" ]; then
          file="$paths/${output//'%(ext)s'/mp4}"
          printf 'fixture video' > "$file"
          stem="${output%%.*}"
          printf '1\\n00:00:00,000 --> 00:00:02,000\\nWelcome.\\n' > "$paths/$stem.en.srt"
          printf 'WL_DONE\\t"%s"\\t"字幕样本"\\t"检查"\\t60\\t[]\\n' "$file"
        fi
        """
        for (name, body) in [("yt-dlp", script), ("ffmpeg", "#!/bin/sh\nexit 0\n")] {
            let path = tools.appendingPathComponent(name); try body.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let f = try fixture(); defer { f.clean() }
        let watched = UUID(), archived = UUID(), old = UUID()
        try JSONSerialization.data(withJSONObject: [try row(f, id: watched, status: "watched"), try row(f, id: archived, status: "archived"), try row(f, id: old, subtitles: false)]).write(to: f.file)
        let range = f.store(); range.startLocalTranscriptionQueue(); defer { range.stopLocalTranscriptionQueue() }
        try check(range.item(with: watched)?.transcriptionState == nil && range.item(with: archived)?.transcriptionState == nil, "已看和已归档的旧条目不得自动转写或登记")
        range.stopLocalTranscriptionQueue()
        let network = NetworkMonitor(); network.start()
        try await wait { network.isOnline }
        let library = f.store(network: network); defer { library.stopLocalTranscriptionQueue() }
        let url = URL(string: "https://example.invalid/new.mp4")!
        _ = library.addBatch([url], activatesApp: false)
        try await wait { library.items.first { $0.urlString == url.absoluteString }?.state == .ready }
        let new = library.items.first { $0.urlString == url.absoluteString }!.id
        library.startLocalTranscriptionQueue()
        try check(library.item(with: watched)?.transcriptionState == nil && library.item(with: archived)?.transcriptionState == nil, "已看和已归档的旧条目不得自动转写或登记")
        try check(library.item(with: new)?.transcriptionState == "not_needed", "新加条目必须优先于排队的旧条目，旧条目时间戳未来也不能抢先")
        library.stopLocalTranscriptionQueue()
        print("library_scope=passed：已看/已归档跳过，新链接先于旧条目")
        fflush(stdout)

        let m = try fixture(); defer { m.clean() }
        let stalled = UUID(), other = UUID()
        let zh = m.media.appendingPathComponent("\(stalled.uuidString).zh-Hans.srt")
        try Data("1\n00:00:00,000 --> 00:00:02,000\n欢迎。\n".utf8).write(to: zh)
        var first = try row(m, id: stalled, url: "https://www.youtube.com/watch?v=Stall000001")
        first["addedAt"] = "2071-01-01T00:00:00Z"
        try JSONSerialization.data(withJSONObject: [first, try row(m, id: other)]).write(to: m.file)
        let queue = m.store(); defer { queue.stopLocalTranscriptionQueue() }
        let started = Date(); queue.startLocalTranscriptionQueue()
        try await wait { FileManager.default.fileExists(atPath: pidFile.path) }
        try await wait { queue.item(with: other)?.transcriptionState == "not_needed" }
        try check(queue.item(with: stalled)?.translationSource == nil, "元数据仍挂起时其他条目必须已处理")
        try await wait({ (queue.item(with: stalled)?.subtitleMetadataFailureCount ?? 0) == 1 }, seconds: 33)
        let elapsed = Date().timeIntervalSince(started)
        try check(elapsed >= 29 && elapsed < 33, "实际30秒截止没有生效")
        try check(queue.item(with: stalled)?.translationSource == nil && queue.item(with: stalled)?.initialSubtitlePath == nil, "首次超时保留未知来源，下次启动再查")
        try check(queue.flushPendingSaves(), "超时来源保存")
        try check(m.store().item(with: stalled)?.subtitleMetadataFailureCount == 1 && m.store().item(with: stalled)?.translationSource == nil, "只保存重查次数，不能落成永久人工来源")
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        try check(kill(pid, 0) != 0 && errno == ESRCH, "本次元数据工具PID必须已退出")
        print(String(format: "metadata_timeout=passed elapsed=%.3fs pid=%d exited=true other_item_completed=true source=unknown retry_count=1", elapsed, pid))
    }
}
