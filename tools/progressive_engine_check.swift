import Darwin
import Foundation

/// 边下边播从真实入口 `DownloadEngine.start` 走一遍，工具都是假的，不联网。
/// 事件名用 Mirror 读，不引用新加的事件，所以旧代码上也能编译运行，并在第一条断言失败。
/// 只能经 scripts/test_progressive_engine.sh 运行：它造一个临时应用和临时家目录。

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

private final class Completion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Swift.Result<Value, Error>?

    func finish(_ value: Swift.Result<Value, Error>) {
        lock.lock()
        result = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(seconds: Double) throws -> Swift.Result<Value, Error> {
        guard semaphore.wait(timeout: .now() + seconds) == .success else {
            throw CheckFailure(description: "DownloadEngine 没有调用完成回调")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw CheckFailure(description: "完成回调没有结果") }
        return result
    }
}

private final class EventLog: @unchecked Sendable {
    struct Entry {
        let name: String
        let detail: String
        let beforeCompletion: Bool
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var completed = false

    func record(_ event: DownloadEngine.Event) {
        let name = Mirror(reflecting: event).children.first?.label ?? String(describing: event)
        lock.lock()
        entries.append(Entry(name: name, detail: String(describing: event), beforeCompletion: !completed))
        lock.unlock()
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    func entries(named name: String) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.name == name }
    }
}

@main
struct ProgressiveEngineCheck {
    static let previewFormat = "b[height<=720][ext=mp4][vcodec!=none][acodec!=none][protocol^=http]/b[height<=720][vcodec!=none][acodec!=none]/best"
    static let downloadFormat = "bv*[height<=1080][ext=mp4]+ba[ext=m4a]/b[height<=1080][ext=mp4]/b[height<=1080]/best"

    static func main() throws {
        guard let rootPath = ProcessInfo.processInfo.environment["PROGRESSIVE_CHECK_ROOT"] else {
            throw CheckFailure(description: "请经 scripts/test_progressive_engine.sh 运行")
        }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let resources = Bundle.main.resourceURL?.resolvingSymlinksInPath().path ?? ""
        try check(resources.hasPrefix(root.path + "/"), "拒绝使用临时应用之外的工具")
        try check(
            Bundle.main.bundleIdentifier == "ai.openmy.seesee.tests.progressive-engine",
            "拒绝在 seesee 的偏好设置域里运行"
        )
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        try check(home.hasPrefix(root.path + "/"), "拒绝在真实的家目录下运行")

        let engine = DownloadEngine()
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        try checkPreviewAndSubtitles(engine: engine, destination: destination, root: root)
        try checkMissingPreviewFallsBack(engine: engine, destination: destination, root: root)
        try checkCancelStopsResolver(engine: engine, destination: destination, root: root)
        print("progressive_engine_check=passed（假工具，不联网：预览流、字幕陆续到达、拿不到预览时退回、删除时停掉解析进程）")
    }

    /// 正常路径：下完之前先拿到预览流；字幕陆续落盘时，更优的那一轨到了要再报一次。
    private static func checkPreviewAndSubtitles(engine: DownloadEngine, destination: URL, root: URL) throws {
        let log = EventLog()
        let done = Completion<DownloadEngine.Result>()
        let source = URL(string: "https://www.youtube.com/watch?v=preview0001")!
        engine.start(
            itemID: UUID(),
            sourceURL: source,
            destination: destination,
            onEvent: log.record,
            completion: { result in
                log.markCompleted()
                done.finish(result)
            }
        )
        let result = try done.wait(seconds: 30).get()
        try check(FileManager.default.fileExists(atPath: result.fileURL.path), "完成回调丢了视频文件")

        let previews = log.entries(named: "playbackSource")
        try check(!previews.isEmpty, "下载过程中没有拿到预览流")
        try check(previews.allSatisfy(\.beforeCompletion), "预览流要在完整画质下完之前到")
        try check(previews.count == 1, "一次下载只该发一次预览流，实际 \(previews.count) 次")
        try check(
            previews[0].detail.contains("https://fixture.invalid/progressive.mp4"),
            "预览地址不对：\(previews[0].detail)"
        )

        let subtitles = log.entries(named: "subtitleFile").filter(\.beforeCompletion).map(\.detail)
        try check(subtitles.count >= 2, "下载中没有陆续报出字幕：\(subtitles)")
        try check(subtitles[0].contains(".en.srt"), "先落盘的英文字幕要先报：\(subtitles)")
        try check(subtitles.last?.contains(".zh.srt") == true, "更优的双语 .zh.srt 到了以后要再报：\(subtitles)")
        try check(!subtitles.contains { $0.contains(".vtt") }, "不报转换前的 .vtt")
        try check(result.subtitleFileURL?.lastPathComponent.hasSuffix(".zh.srt") == true, "完成时的字幕应是最优的 .zh.srt")

        let calls = try recordedCalls(root: root).filter { $0.last?.contains("preview0001") == true }
        let resolver = calls.filter { $0.contains("--get-url") }
        try check(resolver.count == 1, "预览解析应恰好运行一次，实际 \(resolver.count) 次")
        try check(resolver[0].contains("--ignore-config"), "预览解析会读用户的 yt-dlp 配置")
        try check(resolver[0].contains("--no-playlist"), "预览解析没有限制为单个视频")
        try check(
            adjacent(resolver[0], "--extractor-args", "youtube:player_client=android"),
            "预览解析没有走 Android 客户端（拿不到 format 18）"
        )
        try check(adjacent(resolver[0], "--format", previewFormat), "预览格式和上游不一致")
        let downloads = calls.filter { !$0.contains("--get-url") && $0.contains("--output") }
        try check(downloads.count == 1, "完整画质下载应恰好运行一次，实际 \(downloads.count) 次")
        try check(adjacent(downloads[0], "--format", downloadFormat), "完整画质的格式被改动了")
        try check(!downloads[0].contains("youtube:player_client=android"), "完整画质下载不该走 Android 客户端")
    }

    /// 拿不到合流时不发预览事件，下载照常完成，界面退回下完再播。
    private static func checkMissingPreviewFallsBack(engine: DownloadEngine, destination: URL, root: URL) throws {
        let log = EventLog()
        let done = Completion<DownloadEngine.Result>()
        engine.start(
            itemID: UUID(),
            sourceURL: URL(string: "https://www.youtube.com/watch?v=nopreview01")!,
            destination: destination,
            onEvent: log.record,
            completion: { result in
                log.markCompleted()
                done.finish(result)
            }
        )
        let result = try done.wait(seconds: 30).get()
        try check(FileManager.default.fileExists(atPath: result.fileURL.path), "拿不到预览时，完整画质照样要下完")
        // 预览解析在另一个队列上跑，可能比这次很快的假下载晚开始：等它留下调用记录，再多等一会儿让它跑完。
        var resolver: [[String]] = []
        let deadline = Date().addingTimeInterval(10)
        while resolver.isEmpty, Date() < deadline {
            resolver = try recordedCalls(root: root).filter {
                $0.last?.contains("nopreview01") == true && $0.contains("--get-url")
            }
            if resolver.isEmpty { usleep(50_000) }
        }
        try check(resolver.count == 1, "拿不到合流的链接也要先试一次预览解析")
        usleep(500_000)
        try check(log.entries(named: "playbackSource").isEmpty, "拿不到合流时不该发预览事件")
    }

    /// 删除正在解析预览的条目：解析进程和下载进程都要停掉，不留后台进程。
    private static func checkCancelStopsResolver(engine: DownloadEngine, destination: URL, root: URL) throws {
        let itemID = UUID()
        let done = Completion<DownloadEngine.Result>()
        let pids = root.appendingPathComponent("pids", isDirectory: true)
        engine.start(
            itemID: itemID,
            sourceURL: URL(string: "https://www.youtube.com/watch?v=slowresolv1")!,
            destination: destination,
            onEvent: { _ in },
            completion: done.finish
        )
        let resolverPID = try waitForPID(pids.appendingPathComponent("resolver"), what: "预览解析进程")
        let downloadPID = try waitForPID(pids.appendingPathComponent("download"), what: "完整画质下载进程")
        engine.cancel(itemID: itemID)
        try check(waitUntilGone(resolverPID, seconds: 3), "删除后预览解析进程 \(resolverPID) 还在")
        try check(waitUntilGone(downloadPID, seconds: 3), "删除后下载进程 \(downloadPID) 还在")
        if case .success = try done.wait(seconds: 10) {
            throw CheckFailure(description: "被取消的下载不该报成功")
        }
    }

    private static func recordedCalls(root: URL) throws -> [[String]] {
        let folder = root.appendingPathComponent("calls", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map { url in
                String(decoding: try Data(contentsOf: url), as: UTF8.self)
                    .split(separator: "\0", omittingEmptySubsequences: false)
                    .dropLast()
                    .map(String.init)
            }
    }

    private static func adjacent(_ arguments: [String], _ option: String, _ value: String) -> Bool {
        arguments.indices.contains { index in
            arguments[index] == option && index + 1 < arguments.count && arguments[index + 1] == value
        }
    }

    private static func waitForPID(_ file: URL, what: String) throws -> pid_t {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            usleep(50_000)
        }
        throw CheckFailure(description: "\(what)没有启动")
    }

    private static func waitUntilGone(_ pid: pid_t, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            usleep(50_000)
        }
        return false
    }
}
