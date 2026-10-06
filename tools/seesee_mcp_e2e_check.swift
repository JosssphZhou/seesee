import AppKit
import AVFoundation
import Darwin
import Foundation

/// seesee MCP 端到端检查：从真实入口走一遍。
/// 启动给定构建（换了 bundle id 的副本，家目录是临时目录），打开一段带字幕和章节的测试视频，
/// 再起 `seesee --mcp-stdio`，按 MCP 协议依次发 initialize、tools/list，用 tools/call 调三个工具；
/// 最后关掉应用，确认工具返回「seesee 没有运行」且不卡住。
/// 由 tools/seesee_mcp_e2e_check.sh 准备副本和临时家目录后调用，不碰真实的队列、片库和偏好设置。
@main
struct SeeseeMCPEndToEndCheck {
    static let title = "seesee MCP 端到端检查"
    static let author = "seesee"
    static let durationSeconds = 60
    /// 续播位置落在第 30 秒那一帧中间；离片尾超过 10 秒，应用才会续播到这里。
    static let resumeAt = 30.5
    static let cueLength = 2
    /// 每秒一种颜色，相邻两秒差别很大：取到的画面是第几秒，看中心颜色就知道。
    static let palette: [(r: Double, g: Double, b: Double)] = [
        (220, 40, 40), (40, 200, 60), (40, 80, 220), (230, 210, 40), (200, 40, 200), (40, 200, 210)
    ]

    static func main() async {
        let options = Options.parse(CommandLine.arguments)
        var session: Session?
        do {
            let fixture = try await Fixture.make(home: options.home)
            print("夹具：\(fixture.video.lastPathComponent)，\(durationSeconds) 秒，续播在 \(resumeAt) 秒")
            let launched = try launchApp(options)
            session = launched
            try launched.waitForQueryChannel()
            try run(session: launched, fixture: fixture, options: options)
            launched.finish()
            print("seesee_mcp_e2e_check=passed")
        } catch {
            fputs("seesee_mcp_e2e_check 失败：\(error)\n", stderr)
            session?.dumpDiagnostics()
            session?.finish()
            exit(1)
        }
    }

    // MARK: - 主流程

    static func run(session: Session, fixture: Fixture, options: Options) throws {
        let initialize = try session.bridge.request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "seesee-mcp-e2e-check", "version": "1"]
        ])
        let serverInfo = initialize["serverInfo"] as? [String: Any]
        try expect(serverInfo?["name"] as? String == "seesee", "initialize 的 serverInfo.name 应是 seesee：\(initialize)")
        try expect(initialize["protocolVersion"] as? String == "2025-06-18", "协议版本应按客户端请求回 2025-06-18")
        try session.bridge.notify("notifications/initialized")

        let list = try session.bridge.request("tools/list", params: [:])
        let tools = list["tools"] as? [[String: Any]] ?? []
        let names = tools.compactMap { $0["name"] as? String }
        try expect(names == ["now_playing", "current_subtitles", "current_frame"], "tools/list 应是三个工具，实际 \(names)")
        for tool in tools {
            let annotations = tool["annotations"] as? [String: Any]
            try expect(annotations?["readOnlyHint"] as? Bool == true, "\(tool["name"] ?? "") 应标为只读")
        }
        print("tools/list：\(names.joined(separator: "、"))")

        // 视频详情挂上播放器、字幕读完之前查询会回 videoOpen=false，最多等 30 秒。
        var nowPlaying: [String: Any] = [:]
        let openDeadline = Date().addingTimeInterval(30)
        repeat {
            nowPlaying = try session.callJSON("now_playing")
            if nowPlaying["videoOpen"] as? Bool == true { break }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < openDeadline
        try expect(nowPlaying["videoOpen"] as? Bool == true, "30 秒内 now_playing 一直说没有视频打开：\(nowPlaying)")
        try expect(nowPlaying["title"] as? String == title, "now_playing 标题不对：\(nowPlaying["title"] ?? "nil")")
        try expect(nowPlaying["itemID"] as? String == fixture.itemID.uuidString, "now_playing 条目编号不对")
        let position = (nowPlaying["positionSeconds"] as? NSNumber)?.doubleValue ?? -1
        try expect(abs(position - resumeAt) < 1, "播放位置应在续播点 \(resumeAt) 秒附近，实际 \(position)")
        try expect(!(nowPlaying["position"] as? String ?? "").isEmpty, "now_playing 应带时间码")
        let duration = (nowPlaying["durationSeconds"] as? NSNumber)?.doubleValue ?? -1
        try expect(abs(duration - Double(durationSeconds)) < 1, "总时长应约 \(durationSeconds) 秒，实际 \(duration)")
        print("now_playing：《\(title)》\(nowPlaying["position"] ?? "")／\(nowPlaying["duration"] ?? "")，state=\(nowPlaying["state"] ?? "")")

        // 字幕是异步读进来的，字幕轨登记后才有句子。
        var subtitles: [String: Any] = [:]
        let subtitleDeadline = Date().addingTimeInterval(15)
        repeat {
            subtitles = try session.callJSON("current_subtitles", arguments: ["before_seconds": 4, "after_seconds": 4])
            if subtitles["hasSubtitles"] as? Bool == true { break }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < subtitleDeadline
        try expect(subtitles["hasSubtitles"] as? Bool == true, "current_subtitles 应有字幕：\(subtitles)")
        let current = subtitles["current"] as? [String: Any]
        let expected = Fixture.cueLines(index: Int(resumeAt) / cueLength)
        try expect(current?["original"] as? String == expected.original, "当前句原文不对：\(current ?? [:])")
        try expect(current?["translation"] as? String == expected.translation, "当前句译文不对：\(current ?? [:])")
        let cues = subtitles["cues"] as? [[String: Any]] ?? []
        try expect(cues.count >= 3, "前后各 4 秒应至少有 3 句，实际 \(cues.count)")
        print("current_subtitles：当前句「\(expected.original)」「\(expected.translation)」，窗口内 \(cues.count) 句")

        let frame = try session.bridge.callTool("current_frame", arguments: ["max_width": 320])
        try expect(frame["isError"] as? Bool == false, "current_frame 不应报错：\(frame)")
        let content = frame["content"] as? [[String: Any]] ?? []
        let image = content.first { $0["type"] as? String == "image" }
        try expect(image?["mimeType"] as? String == "image/jpeg", "current_frame 应回 JPEG")
        let data = Data(base64Encoded: image?["data"] as? String ?? "") ?? Data()
        try expect(data.starts(with: [0xFF, 0xD8, 0xFF]), "current_frame 的数据不是 JPEG")
        guard let bitmap = NSBitmapImageRep(data: data) else { throw CheckFailure("current_frame 的图片解不开") }
        try expect(bitmap.pixelsWide > 0 && bitmap.pixelsWide <= 320, "画面宽度应在 1 到 320 之间，实际 \(bitmap.pixelsWide)")
        let frameSecond = Int(resumeAt)
        let match = nearestPaletteIndex(bitmap)
        try expect(match.index == frameSecond % palette.count, "画面应是第 \(frameSecond) 秒那一帧，中心颜色 \(match.rgb) 更像第 \(match.index) 种颜色")
        let caption = content.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        try expect(caption.contains(title), "画面说明应带标题：\(caption)")
        print("current_frame：JPEG \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)，\(data.count) 字节，中心颜色 \(match.rgb) 对上第 \(frameSecond) 秒")

        // 失败路径：应用关掉以后，工具要马上说明 seesee 没有运行，不能卡住。
        try session.stopApp()
        for tool in ["now_playing", "current_frame"] {
            let started = Date()
            let reply = try session.callJSON(tool)
            let elapsed = Date().timeIntervalSince(started)
            try expect(reply["videoOpen"] as? Bool == false, "应用关掉后 \(tool) 应说没有视频打开：\(reply)")
            try expect(reply["message"] as? String == "seesee 没有运行", "应用关掉后 \(tool) 应说 seesee 没有运行：\(reply)")
            try expect(elapsed < 3, "应用关掉后 \(tool) 用了 \(elapsed) 秒才回答")
            print("应用关掉后 \(tool)：\(String(format: "%.2f", elapsed)) 秒返回「seesee 没有运行」")
        }
    }

    static func nearestPaletteIndex(_ bitmap: NSBitmapImageRep) -> (index: Int, rgb: String) {
        let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        let r = Double(color?.redComponent ?? 0) * 255
        let g = Double(color?.greenComponent ?? 0) * 255
        let b = Double(color?.blueComponent ?? 0) * 255
        let distances = palette.map { pow($0.r - r, 2) + pow($0.g - g, 2) + pow($0.b - b, 2) }
        let index = distances.indices.min { distances[$0] < distances[$1] } ?? -1
        return (index, "(\(Int(r)), \(Int(g)), \(Int(b)))")
    }

    // MARK: - 启动应用

    static func launchApp(_ options: Options) throws -> Session {
        let log = URL(fileURLWithPath: options.home).appendingPathComponent("app.log").path
        FileManager.default.createFile(atPath: log, contents: nil)
        // -g 不抢前台；-n 另开实例；--env 把家目录换成临时目录。
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [
            "-g", "-n", "-F",
            "--env", "CFFIXED_USER_HOME=\(options.home)",
            "--stdout", log, "--stderr", log,
            options.app
        ]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw CheckFailure("open 启动应用失败，退出码 \(open.terminationStatus)") }

        var app: NSRunningApplication?
        let launchDeadline = Date().addingTimeInterval(20)
        while app == nil, Date() < launchDeadline {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleID).first
            if app == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard let app else { throw CheckFailure("20 秒内没看到 \(options.bundleID) 启动") }
        let session = Session(app: app, appPath: options.app, home: options.home, log: log)
        let launchedPath = app.bundleURL.map { canonicalPath($0.path) } ?? "nil"
        guard launchedPath == canonicalPath(options.app) else {
            session.finish()
            throw CheckFailure("启动的不是被测副本：\(launchedPath)")
        }
        return session
    }

    /// /tmp 与 /private/tmp 是同一个目录，比较前先解开符号链接。
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw CheckFailure(message()) }
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var app = ""
    var home = ""
    var bundleID = ""

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var iterator = arguments.dropFirst().makeIterator()
        while let flag = iterator.next() {
            let value = iterator.next() ?? ""
            switch flag {
            case "--app": options.app = value
            case "--home": options.home = value
            case "--bundle-id": options.bundleID = value
            default: break
            }
        }
        guard !options.app.isEmpty, !options.home.isEmpty, !options.bundleID.isEmpty else {
            fputs("用法：seesee_mcp_e2e_check --app <应用副本> --home <临时家目录> --bundle-id <副本的 bundle id>\n", stderr)
            exit(2)
        }
        return options
    }
}

// MARK: - 夹具：一段 60 秒、每秒一种颜色的视频，双语字幕和三个章节，队列里只有这一条

struct Fixture {
    let itemID: UUID
    let video: URL

    static func cueLines(index: Int) -> (original: String, translation: String) {
        ("Line \(index + 1) of the seesee check.", "检查视频第 \(index + 1) 句。")
    }

    static func make(home: String) async throws -> Fixture {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        let media = homeURL.appendingPathComponent("Movies/seesee", isDirectory: true)
        let support = homeURL.appendingPathComponent("Library/Application Support/seesee", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let itemID = UUID()
        let video = media.appendingPathComponent("\(itemID.uuidString).mp4")
        let subtitle = media.appendingPathComponent("\(itemID.uuidString).en.srt")
        try await writeVideo(to: video)
        try srt().write(to: subtitle, atomically: true, encoding: .utf8)

        let total = Double(SeeseeMCPEndToEndCheck.durationSeconds)
        let item = WatchItem(
            id: itemID,
            urlString: "https://example.com/seesee-mcp-check",
            title: SeeseeMCPEndToEndCheck.title,
            author: SeeseeMCPEndToEndCheck.author,
            duration: total,
            addedAt: Date(),
            watchedAt: nil,
            state: .ready,
            progress: 1,
            progressLabel: "",
            localFilePath: video.path,
            errorMessage: nil,
            playbackPosition: SeeseeMCPEndToEndCheck.resumeAt,
            chapters: [
                VideoChapter(title: "开场", startTime: 0, endTime: 20),
                VideoChapter(title: "中段", startTime: 20, endTime: 40),
                VideoChapter(title: "结尾", startTime: 40, endTime: total)
            ],
            thumbnailFilePath: nil,
            subtitleFilePath: subtitle.path
        )
        // 与 QueueStore 落盘同一编码方式。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([item]).write(to: support.appendingPathComponent("queue.json"), options: .atomic)
        return Fixture(itemID: itemID, video: video)
    }

    static func srt() -> String {
        let length = SeeseeMCPEndToEndCheck.cueLength
        return stride(from: 0, to: SeeseeMCPEndToEndCheck.durationSeconds, by: length).enumerated().map { index, start in
            let lines = cueLines(index: index)
            return "\(index + 1)\n\(timestamp(start)) --> \(timestamp(start + length))\n\(lines.original)\n\(lines.translation)\n"
        }.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d,000", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    static func writeVideo(to url: URL) async throws {
        let width = 320
        let height = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw CheckFailure("写测试视频失败：\(writer.error.map(String.init(describing:)) ?? "未知原因")") }
        writer.startSession(atSourceTime: .zero)
        for second in 0..<SeeseeMCPEndToEndCheck.durationSeconds {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CheckFailure("建不了像素缓冲") }
            let color = SeeseeMCPEndToEndCheck.palette[second % SeeseeMCPEndToEndCheck.palette.count]
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let pixels = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * bytesPerRow + x * 4
                        pixels[offset] = UInt8(color.b)
                        pixels[offset + 1] = UInt8(color.g)
                        pixels[offset + 2] = UInt8(color.r)
                        pixels[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(second), timescale: 1)) else {
                throw CheckFailure("写第 \(second) 秒画面失败：\(writer.error.map(String.init(describing:)) ?? "未知原因")")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(SeeseeMCPEndToEndCheck.durationSeconds), timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CheckFailure("测试视频没写完：\(writer.error.map(String.init(describing:)) ?? "未知原因")")
        }
    }
}

// MARK: - 被测应用与 MCP 桥接进程

final class Session {
    let app: NSRunningApplication
    let appPath: String
    let home: String
    let log: String
    private(set) var bridge: BridgeClient!

    init(app: NSRunningApplication, appPath: String, home: String, log: String) {
        self.app = app
        self.appPath = appPath
        self.home = home
        self.log = log
    }

    /// 等应用在临时家目录里开出查询通道，再起桥接进程。
    func waitForQueryChannel() throws {
        let socket = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/seesee/agent-link/now-playing.sock").path
        let deadline = Date().addingTimeInterval(20)
        while !SeeseeMCPEndToEndCheck.isSocket(socket), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard SeeseeMCPEndToEndCheck.isSocket(socket) else {
            throw CheckFailure("查询通道没有在临时家目录里启动：\(socket)")
        }
        print("应用已在临时家目录启动（pid \(app.processIdentifier)），查询通道：\(socket)")
        bridge = try BridgeClient(executable: appPath + "/Contents/MacOS/seesee", home: home)
    }

    /// tools/call 的文字结果按 JSON 解开。
    func callJSON(_ tool: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        let result = try bridge.callTool(tool, arguments: arguments)
        let content = result["content"] as? [[String: Any]] ?? []
        guard result["isError"] as? Bool == false,
              let text = content.first?["text"] as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw CheckFailure("\(tool) 没有回 JSON 文字：\(result)") }
        return object
    }

    /// 这里没有运行循环，NSRunningApplication.isTerminated 不会刷新，直接问进程还在不在。
    var isAppRunning: Bool {
        kill(app.processIdentifier, 0) == 0 || errno != ESRCH
    }

    func stopApp() throws {
        kill(app.processIdentifier, SIGTERM)
        let deadline = Date().addingTimeInterval(10)
        while isAppRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if isAppRunning {
            kill(app.processIdentifier, SIGKILL)
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard !isAppRunning else { throw CheckFailure("关不掉被测应用 pid \(app.processIdentifier)") }
    }

    func finish() {
        bridge?.close()
        if isAppRunning {
            kill(app.processIdentifier, SIGTERM)
            let deadline = Date().addingTimeInterval(5)
            while isAppRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if isAppRunning { kill(app.processIdentifier, SIGKILL) }
        }
    }

    func dumpDiagnostics() {
        if let bridge { fputs("桥接进程标准错误：\n\(bridge.stderrText)\n", stderr) }
        if let text = try? String(contentsOfFile: log, encoding: .utf8) {
            fputs("应用日志最后 40 行：\n\(text.split(separator: "\n").suffix(40).joined(separator: "\n"))\n", stderr)
        }
    }
}

/// 逐行收发 JSON-RPC：标准输入写一行请求，标准输出读一行回答。
final class BridgeClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var lines: [String] = []
    private var buffer = Data()
    private var errorData = Data()
    private var nextID = 1

    init(executable: String, home: String) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--mcp-stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock(); self.errorData.append(data); self.lock.unlock()
        }
        try process.run()
    }

    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errorData, as: UTF8.self)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var complete: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            complete.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lines.append(contentsOf: complete)
        lock.unlock()
        for _ in complete { arrived.signal() }
    }

    private func nextLine(timeout: TimeInterval) throws -> String {
        guard arrived.wait(timeout: .now() + timeout) == .success else {
            throw CheckFailure("MCP 进程 \(Int(timeout)) 秒内没有回答")
        }
        lock.lock(); defer { lock.unlock() }
        return lines.removeFirst()
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        input.fileHandleForWriting.write(data + Data([0x0A]))
    }

    func notify(_ method: String) throws {
        try send(["jsonrpc": "2.0", "method": method])
    }

    func request(_ method: String, params: [String: Any], timeout: TimeInterval = 15) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let line = try nextLine(timeout: timeout)
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw CheckFailure("\(method) 的回答不是 JSON 对象：\(line.prefix(200))")
        }
        guard object["id"] as? Int == id else { throw CheckFailure("\(method) 的回答编号不对：\(line.prefix(200))") }
        if let error = object["error"] { throw CheckFailure("\(method) 返回错误：\(error)") }
        guard let result = object["result"] as? [String: Any] else { throw CheckFailure("\(method) 没有 result：\(line.prefix(200))") }
        return result
    }

    func callTool(_ name: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        try request("tools/call", params: ["name": name, "arguments": arguments])
    }

    func close() {
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }
}
