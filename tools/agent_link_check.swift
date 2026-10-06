import Darwin
import Foundation

/// 本机查询通道：真实 Unix 域套接字、令牌鉴权、权限、请求上限、读超时、连接数上限、路径被占时不启动。
@main
struct AgentLinkCheck {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        checkTokenComparison()
        checkPeerPolicy()
        checkPermissionsAndAuth()
        checkTokenRegeneratedEachStart()
        checkMissingTokenMeansNotRunning()
        checkOversizedRequestDisconnected()
        checkReadTimeout()
        checkConnectionLimit()
        checkOccupiedPathKeptIntact()
        checkStaleSocketReplaced()
        checkOverlongPathRefused()
        checkStopRemovesOwnFiles()
        print("agent_link_check=passed")
    }

    // MARK: - 夹具

    /// 假查询提供者：记录收到的请求，回显查询名。真实鉴权、协议、套接字都走生产代码。
    final class RecordingProvider: AgentLinkQueryProvider {
        private let lock = NSLock()
        private var _requests: [AgentLinkRequest] = []
        var requests: [AgentLinkRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        func answer(_ request: AgentLinkRequest) -> AgentLinkReply {
            lock.lock(); _requests.append(request); lock.unlock()
            return .success([
                "query": request.query.rawValue,
                "positionSeconds": 42,
                "videoOpen": true,
                "playing": false,
                "state": "paused"
            ])
        }
    }

    final class LogSink {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return _lines
        }
        func append(_ line: String) {
            lock.lock(); _lines.append(line); lock.unlock()
        }
    }

    private static func makeRoot() -> URL {
        // 放在 /tmp 下：套接字路径要短于 sun_path 上限。
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("alc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func makeServer(
        root: URL,
        provider: AgentLinkQueryProvider = RecordingProvider(),
        log: LogSink = LogSink()
    ) -> (AgentLinkServer, AgentLinkPaths) {
        let paths = AgentLinkPaths(directory: root.appendingPathComponent("agent-link", isDirectory: true))
        let server = AgentLinkServer(paths: paths, provider: provider, log: { log.append($0) })
        return (server, paths)
    }

    private static func mode(_ url: URL) -> mode_t {
        var info = stat()
        precondition(lstat(url.path, &info) == 0, "stat 失败：\(url.path)")
        return info.st_mode
    }

    private static func connectRaw(_ paths: AgentLinkPaths) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(paths.socket.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(result == 0, "连接套接字失败：errno \(errno)")
        return fd
    }

    /// 读到对端关闭或超时；返回读到的字节和是否被对端关闭。
    private static func readUntilClosed(_ fd: Int32, timeout: Double) -> (Data, closed: Bool) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0 { return (data, true) }
            if errno == ECONNRESET { return (data, true) }
            return (data, false)
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private static func token(_ paths: AgentLinkPaths) -> String {
        (try? String(contentsOf: paths.token, encoding: .utf8)) ?? ""
    }

    private static func send(_ paths: AgentLinkPaths, token: String, query: AgentLinkRequest.Query = .nowPlaying) -> AgentLinkClient.Outcome {
        AgentLinkClient.send(
            AgentLinkRequest(token: token, query: query, before: 30, after: 30, maxWidth: 1024),
            paths: paths,
            timeout: 5
        )
    }

    // MARK: - 检查

    private static func checkTokenComparison() {
        precondition(AgentLinkToken.matches("abcd", "abcd"), "相同令牌通过")
        precondition(!AgentLinkToken.matches("abcd", "abce"), "末位不同不通过")
        precondition(!AgentLinkToken.matches("abc", "abcd"), "长度不同不通过")
        precondition(!AgentLinkToken.matches("", ""), "空令牌不通过")
        let generated = AgentLinkToken.generate()
        precondition(generated.count == 64 && generated.allSatisfy { $0.isHexDigit }, "令牌是 32 字节的十六进制串：\(generated.count)")
        precondition(generated != AgentLinkToken.generate(), "每次生成的令牌不同")
    }

    private static func checkPeerPolicy() {
        precondition(AgentLinkPeerPolicy.allows(peerUID: 501, ownUID: 501), "同一用户可连")
        precondition(!AgentLinkPeerPolicy.allows(peerUID: 0, ownUID: 501), "别的用户（含 root）不可连")
        precondition(!AgentLinkPeerPolicy.allows(peerUID: nil, ownUID: 501), "取不到对端用户不可连")
    }

    private static func checkPermissionsAndAuth() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let log = LogSink()
        let (server, paths) = makeServer(root: root, provider: provider, log: log)
        precondition(server.start() == .started, "服务应当启动")
        defer { server.stop() }

        precondition(mode(paths.directory) & 0o777 == 0o700, "目录权限 0700：\(String(mode(paths.directory) & 0o777, radix: 8))")
        precondition(mode(paths.directory) & S_IFMT == S_IFDIR, "目录类型")
        precondition(mode(paths.socket) & S_IFMT == S_IFSOCK, "套接字类型")
        precondition(mode(paths.socket) & 0o777 == 0o600, "套接字权限 0600：\(String(mode(paths.socket) & 0o777, radix: 8))")
        precondition(mode(paths.token) & 0o777 == 0o600, "令牌权限 0600：\(String(mode(paths.token) & 0o777, radix: 8))")
        precondition(mode(paths.token) & S_IFMT == S_IFREG, "令牌是普通文件")
        let good = token(paths)
        precondition(good.count == 64, "令牌文件内容是 64 位十六进制：\(good.count)")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: paths.directory.path)) ?? []
        precondition(Set(leftovers) == ["now-playing.sock", "token"], "不留下临时文件：\(leftovers)")

        guard case .reply(.success(let payload)) = send(paths, token: good, query: .subtitles) else {
            preconditionFailure("正确令牌应拿到结果")
        }
        precondition(payload["query"] as? String == "subtitles", "结果来自查询提供者：\(payload)")
        // 暂停时的状态字段经过套接字后仍是布尔值和字符串，false 不会变成 0。
        for key in ["videoOpen", "playing"] {
            precondition(
                payload[key].map { CFGetTypeID($0 as CFTypeRef) == CFBooleanGetTypeID() } == true,
                "\(key) 经过套接字后仍是布尔值：\(payload)"
            )
        }
        precondition(
            payload["videoOpen"] as? Bool == true && payload["playing"] as? Bool == false && payload["state"] as? String == "paused",
            "暂停状态字段原样送达：\(payload)"
        )
        precondition(provider.requests.count == 1, "提供者被调用一次")

        let wrong = String(repeating: "0", count: 64)
        guard case .reply(.failure(let code, _)) = send(paths, token: wrong) else {
            preconditionFailure("错误令牌应得到失败回答")
        }
        precondition(code == "unauthorized", "错误令牌：unauthorized，实际 \(code)")
        precondition(provider.requests.count == 1, "鉴权失败时不调用提供者")

        // 原始连接：错误令牌的回答里不带令牌。
        let fd = connectRaw(paths)
        _ = writeAll(fd, Data("{\"token\":\"\(wrong)\",\"query\":\"now_playing\"}\n".utf8))
        let (raw, _) = readUntilClosed(fd, timeout: 3)
        close(fd)
        let rawText = String(decoding: raw, as: UTF8.self)
        precondition(rawText.contains("unauthorized") && !rawText.contains(good) && !rawText.contains(wrong), "回答不含令牌：\(rawText)")

        // 令牌对，查询名不认识。
        let bad = connectRaw(paths)
        _ = writeAll(bad, Data("{\"token\":\"\(good)\",\"query\":\"play\"}\n".utf8))
        let (badReply, _) = readUntilClosed(bad, timeout: 3)
        close(bad)
        precondition(String(decoding: badReply, as: UTF8.self).contains("bad_request"), "不认识的查询：bad_request")
        let notJSON = connectRaw(paths)
        _ = writeAll(notJSON, Data("hello\n".utf8))
        let (notJSONReply, _) = readUntilClosed(notJSON, timeout: 3)
        close(notJSON)
        precondition(String(decoding: notJSONReply, as: UTF8.self).contains("bad_request"), "不是 JSON：bad_request")
        precondition(provider.requests.count == 1, "坏请求不调用提供者")

        precondition(!log.lines.joined(separator: "\n").contains(good), "令牌不进日志")
    }

    private static func checkTokenRegeneratedEachStart() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (first, paths) = makeServer(root: root)
        precondition(first.start() == .started)
        let firstToken = token(paths)
        first.stop()
        let (second, _) = makeServer(root: root)
        precondition(second.start() == .started, "旧套接字清掉后可以再次启动")
        defer { second.stop() }
        let secondToken = token(paths)
        precondition(firstToken.count == 64 && secondToken.count == 64 && firstToken != secondToken, "每次启动生成新令牌")
        guard case .reply(.failure(let code, _)) = send(paths, token: firstToken) else {
            preconditionFailure("旧令牌应被拒绝")
        }
        precondition(code == "unauthorized", "旧令牌：unauthorized")
    }

    private static func checkMissingTokenMeansNotRunning() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentLinkPaths(directory: root.appendingPathComponent("agent-link", isDirectory: true))
        guard case .notRunning = AgentLinkClient.send(
            AgentLinkRequest(token: nil, query: .nowPlaying, before: 30, after: 30, maxWidth: 1024),
            paths: paths,
            timeout: 2
        ) else {
            preconditionFailure("令牌文件不存在：没有运行")
        }
        // 应用崩溃后留下令牌但套接字连不上：同样是没有运行。
        try? FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try? "deadbeef".write(to: paths.token, atomically: true, encoding: .utf8)
        guard case .notRunning = AgentLinkClient.send(
            AgentLinkRequest(token: nil, query: .nowPlaying, before: 30, after: 30, maxWidth: 1024),
            paths: paths,
            timeout: 2
        ) else {
            preconditionFailure("令牌在、套接字不在：没有运行")
        }
    }

    private static func checkOversizedRequestDisconnected() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingProvider()
        let (server, paths) = makeServer(root: root, provider: provider)
        precondition(server.start() == .started)
        defer { server.stop() }
        let good = token(paths)

        // 刚好在上限内的合法请求仍然能用。
        let padding = String(repeating: "p", count: 15_000)
        let fits = connectRaw(paths)
        _ = writeAll(fits, Data("{\"token\":\"\(good)\",\"query\":\"now_playing\",\"pad\":\"\(padding)\"}\n".utf8))
        let (fitsReply, _) = readUntilClosed(fits, timeout: 3)
        close(fits)
        precondition(String(decoding: fitsReply, as: UTF8.self).contains("\"ok\":true"), "上限内的请求正常回答")

        let fd = connectRaw(paths)
        let big = Data(repeating: UInt8(ascii: "a"), count: AgentLinkServer.maxRequestBytes + 1)
        _ = writeAll(fd, big)
        let start = Date()
        let (reply, closed) = readUntilClosed(fd, timeout: 3)
        close(fd)
        precondition(closed && reply.isEmpty, "超过 16 KB 直接断开且不回答：closed=\(closed) bytes=\(reply.count)")
        precondition(Date().timeIntervalSince(start) < 1.5, "超限立即断开，不等读超时")
        precondition(provider.requests.count == 1, "超限请求不调用提供者")

        // 超过上限但带着换行的请求同样断开。
        let fd2 = connectRaw(paths)
        let overWithNewline = String(repeating: "b", count: AgentLinkServer.maxRequestBytes + 10) + "\n"
        _ = writeAll(fd2, Data(overWithNewline.utf8))
        let (reply2, closed2) = readUntilClosed(fd2, timeout: 3)
        close(fd2)
        precondition(closed2 && reply2.isEmpty, "超限一行也断开")
    }

    private static func checkReadTimeout() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, paths) = makeServer(root: root)
        precondition(server.start() == .started)
        defer { server.stop() }

        let fd = connectRaw(paths)
        let start = Date()
        let (reply, closed) = readUntilClosed(fd, timeout: 5)
        let elapsed = Date().timeIntervalSince(start)
        close(fd)
        precondition(closed && reply.isEmpty, "不发请求的连接被断开")
        precondition(elapsed >= 1.5 && elapsed < 3.5, "读超时约 2 秒：\(elapsed)")

        // 慢速逐字节发送也受总时限约束。
        let slow = connectRaw(paths)
        let slowStart = Date()
        var closedEarly = false
        for _ in 0..<8 {
            if !writeAll(slow, Data("{".utf8)) { closedEarly = true; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let (_, slowClosed) = readUntilClosed(slow, timeout: 3)
        close(slow)
        precondition(closedEarly || slowClosed, "慢速发送同样被断开")
        precondition(Date().timeIntervalSince(slowStart) < 7, "慢速发送不能无限占住连接")
    }

    private static func checkConnectionLimit() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, paths) = makeServer(root: root)
        precondition(server.start() == .started)
        defer { server.stop() }

        let idle = (0..<AgentLinkServer.maxConnections).map { _ in connectRaw(paths) }
        Thread.sleep(forTimeInterval: 0.3)
        let extra = connectRaw(paths)
        let start = Date()
        let (reply, closed) = readUntilClosed(extra, timeout: 1.2)
        close(extra)
        precondition(closed && reply.isEmpty, "超过同时连接上限的连接被立刻断开")
        precondition(Date().timeIntervalSince(start) < 1.0, "超限连接不排队等待")
        idle.forEach { close($0) }
        Thread.sleep(forTimeInterval: 0.3)
        guard case .reply(.success) = send(paths, token: token(paths)) else {
            preconditionFailure("空闲连接断开后恢复服务")
        }
    }

    private static func checkOccupiedPathKeptIntact() {
        for kind in ["file", "directory", "symlink"] {
            let root = makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let log = LogSink()
            let (server, paths) = makeServer(root: root, log: log)
            try? FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
            let pinned = Date(timeIntervalSince1970: 1_600_000_000)
            switch kind {
            case "file":
                try? Data("别删我".utf8).write(to: paths.socket)
                try? FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: paths.socket.path)
            case "directory":
                try? FileManager.default.createDirectory(at: paths.socket, withIntermediateDirectories: false)
                try? Data("里面的东西".utf8).write(to: paths.socket.appendingPathComponent("keep"))
            default:
                let target = root.appendingPathComponent("target.txt")
                try? Data("目标".utf8).write(to: target)
                symlink(target.path, paths.socket.path)
            }

            let result = server.start()
            guard case .refused(let reason) = result else { preconditionFailure("\(kind)：路径被占时不启动") }
            precondition(reason.contains("不是套接字"), "\(kind)：拒绝原因写明：\(reason)")
            precondition(log.lines.contains { $0.contains("不是套接字") }, "\(kind)：记录一条日志")
            precondition(!FileManager.default.fileExists(atPath: paths.token.path), "\(kind)：不启动时不写令牌")

            switch kind {
            case "file":
                precondition(mode(paths.socket) & S_IFMT == S_IFREG, "普通文件原样保留")
                precondition((try? Data(contentsOf: paths.socket)) == Data("别删我".utf8), "普通文件内容不变")
                let modified = (try? FileManager.default.attributesOfItem(atPath: paths.socket.path)[.modificationDate]) as? Date
                precondition(modified == pinned, "普通文件修改时间不变：\(String(describing: modified))")
            case "directory":
                precondition(mode(paths.socket) & S_IFMT == S_IFDIR, "目录原样保留")
                precondition(FileManager.default.fileExists(atPath: paths.socket.appendingPathComponent("keep").path), "目录内容保留")
            default:
                precondition(mode(paths.socket) & S_IFMT == S_IFLNK, "符号链接原样保留")
                precondition((try? String(contentsOf: root.appendingPathComponent("target.txt"), encoding: .utf8)) == "目标", "链接目标不变")
            }

            guard case .occupied(let occupiedPath) = AgentLinkClient.send(
                AgentLinkRequest(token: nil, query: .nowPlaying, before: 30, after: 30, maxWidth: 1024),
                paths: paths,
                timeout: 2
            ) else {
                preconditionFailure("\(kind)：桥接端能认出路径被占")
            }
            precondition(occupiedPath == paths.socket.path, "被占路径：\(occupiedPath)")
            server.stop()
            precondition(FileManager.default.fileExists(atPath: paths.socket.path) || kind == "symlink", "\(kind)：stop 不删别人的文件")
            precondition(mode(paths.socket) & S_IFMT != S_IFSOCK, "\(kind)：stop 后仍是原来的类型")
        }

        // 目录本身被符号链接替换：不启动。
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let (server, paths) = makeServer(root: root)
        symlink(elsewhere.path, paths.directory.path)
        guard case .refused = server.start() else { preconditionFailure("目录是符号链接时不启动") }
        precondition(((try? FileManager.default.contentsOfDirectory(atPath: elsewhere.path)) ?? ["x"]).isEmpty, "不往链接目标里写东西")
    }

    private static func checkStaleSocketReplaced() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, paths) = makeServer(root: root)
        try? FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        // 模拟上次崩溃留下的套接字文件：绑定后不删就关掉。
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(paths.socket.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0, "准备旧套接字失败")
        close(fd)
        precondition(mode(paths.socket) & S_IFMT == S_IFSOCK)

        precondition(server.start() == .started, "旧文件是套接字时删掉重建")
        defer { server.stop() }
        guard case .reply(.success) = send(paths, token: token(paths)) else {
            preconditionFailure("重建后可以查询")
        }
    }

    private static func checkOverlongPathRefused() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent(String(repeating: "长", count: 40), isDirectory: true)
        let paths = AgentLinkPaths(directory: deep.appendingPathComponent("agent-link", isDirectory: true))
        precondition(paths.socket.path.utf8.count >= AgentLinkPaths.socketPathLimit, "夹具路径要超过上限")
        let log = LogSink()
        let server = AgentLinkServer(paths: paths, provider: RecordingProvider(), log: { log.append($0) })
        guard case .refused(let reason) = server.start() else { preconditionFailure("路径超长不启动") }
        precondition(reason.contains("太长"), "拒绝原因：\(reason)")
        precondition(!log.lines.isEmpty, "记录日志")
        precondition(!FileManager.default.fileExists(atPath: paths.directory.path), "路径超长时不建目录")
    }

    private static func checkStopRemovesOwnFiles() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, paths) = makeServer(root: root)
        precondition(server.start() == .started)
        let good = token(paths)
        server.stop()
        precondition(!FileManager.default.fileExists(atPath: paths.socket.path), "退出时删掉自己的套接字")
        precondition(!FileManager.default.fileExists(atPath: paths.token.path), "退出时删掉自己的令牌")
        guard case .notRunning = send(paths, token: good) else { preconditionFailure("停止后是没有运行") }
        server.stop()

        // 退出前令牌文件被换成了别人的文件：不删。
        let (again, _) = makeServer(root: root)
        precondition(again.start() == .started)
        try? FileManager.default.removeItem(at: paths.token)
        try? Data("别人的".utf8).write(to: paths.token)
        again.stop()
        precondition((try? Data(contentsOf: paths.token)) == Data("别人的".utf8), "只删自己创建的令牌文件")
    }
}
