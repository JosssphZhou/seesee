import Darwin
import Foundation

/// 本机只读查询通道的文件位置：`<Application Support>/seesee/agent-link/` 下的套接字和令牌。
struct AgentLinkPaths: Equatable {
    static let directoryName = "agent-link"
    static let socketName = "now-playing.sock"
    static let tokenName = "token"
    /// `sockaddr_un.sun_path` 的容量，含结尾的 0；路径字节数必须小于它。
    static let socketPathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    let directory: URL

    var socket: URL { directory.appendingPathComponent(Self.socketName, isDirectory: false) }
    var token: URL { directory.appendingPathComponent(Self.tokenName, isDirectory: false) }

    /// 与 QueueStore 同一个应用数据目录。
    static func standard(fileManager: FileManager = .default) -> AgentLinkPaths {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AgentLinkPaths(
            directory: applicationSupport
                .appendingPathComponent(AppFolders.applicationName, isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        )
    }
}

enum AgentLinkToken {
    /// 每次应用启动新生成：32 字节随机数的十六进制串。
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 定长比较：比较耗时不随第一个不同字节的位置变化。
    static func matches(_ presented: String, _ expected: String) -> Bool {
        let lhs = Array(presented.utf8)
        let rhs = Array(expected.utf8)
        guard !rhs.isEmpty, lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<rhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

enum AgentLinkPeerPolicy {
    /// 只接受与应用同一用户的连接。
    static func allows(peerUID: uid_t?, ownUID: uid_t) -> Bool {
        guard let peerUID else { return false }
        return peerUID == ownUID
    }
}

/// 工具参数原样转过来的 JSON 对象；校验在应用端做。
struct AgentLinkArguments: Equatable {
    static let empty = AgentLinkArguments([:])

    let values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }

    subscript(key: String) -> Any? { values[key] }

    static func == (lhs: AgentLinkArguments, rhs: AgentLinkArguments) -> Bool {
        NSDictionary(dictionary: lhs.values).isEqual(to: rhs.values)
    }
}

/// 套接字请求：一行 JSON。`token` 为 nil 时由客户端现读令牌文件。
struct AgentLinkRequest: Equatable {
    enum Query: String {
        case nowPlaying = "now_playing"
        case subtitles
        case frame
        case listQueue = "list_queue"
        case moveItems = "move_items"
        case addLinks = "add_links"
        case searchSubtitles = "search_subtitles"
        case seekTo = "seek_to"
        case writeChapters = "write_chapters"
        case readSubtitles = "read_subtitles"
        case writeSubtitleTranslations = "write_subtitle_translations"
        case restoreInitialTranslation = "restore_initial_translation"

        /// 待播清单的七个查询；其余三个是正在播放的查询。
        var isQueueQuery: Bool {
            switch self {
            case .nowPlaying, .subtitles, .frame: return false
            default: return true
            }
        }
    }

    var token: String?
    var query: Query
    var before: Double
    var after: Double
    var maxWidth: Double
    var arguments: AgentLinkArguments = .empty

    enum ParseOutcome: Equatable {
        case request(AgentLinkRequest)
        case unauthorized
        case badRequest
    }

    func jsonLine(token resolvedToken: String) -> Data {
        var object: [String: Any] = [
            "token": resolvedToken,
            "query": query.rawValue,
            "before": before,
            "after": after,
            "maxWidth": maxWidth
        ]
        if !arguments.values.isEmpty {
            object["arguments"] = arguments.values
        }
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// 先验令牌再认查询；数值参数原样带出，由结果构造负责夹到范围内。
    static func parse(_ line: Data, expectedToken: String) -> ParseOutcome {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .badRequest
        }
        guard let token = object["token"] as? String, AgentLinkToken.matches(token, expectedToken) else {
            return .unauthorized
        }
        guard let raw = object["query"] as? String, let query = Query(rawValue: raw) else {
            return .badRequest
        }
        func number(_ key: String) -> Double {
            (object[key] as? NSNumber)?.doubleValue ?? .nan
        }
        var arguments = AgentLinkArguments.empty
        if let raw = object["arguments"] {
            guard let values = raw as? [String: Any] else { return .badRequest }
            arguments = AgentLinkArguments(values)
        }
        return .request(AgentLinkRequest(
            token: nil,
            query: query,
            before: number("before"),
            after: number("after"),
            maxWidth: number("maxWidth"),
            arguments: arguments
        ))
    }
}

/// 套接字回答：`{"ok":true,"result":{…}}` 或 `{"ok":false,"error":"…"}`。
enum AgentLinkReply {
    case success([String: Any])
    case failure(code: String, message: String?)

    static let unauthorized = "unauthorized"
    static let badRequest = "bad_request"
    static let frameUnavailable = "frame_unavailable"
    static let busy = "busy"

    func jsonLine() -> Data {
        var object: [String: Any]
        switch self {
        case .success(let result):
            object = ["ok": true, "result": result]
        case .failure(let code, let message):
            object = ["ok": false, "error": code]
            if let message { object["message"] = message }
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"ok":false,"error":"internal"}"#.utf8)
        data.append(0x0A)
        return data
    }

    static func parse(_ data: Data) -> AgentLinkReply? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ok = object["ok"] as? Bool else { return nil }
        if ok {
            return .success(object["result"] as? [String: Any] ?? [:])
        }
        return .failure(code: object["error"] as? String ?? "internal", message: object["message"] as? String)
    }
}

/// 应用端回答查询的一方；在后台线程被调用。
protocol AgentLinkQueryProvider: AnyObject {
    func answer(_ request: AgentLinkRequest) -> AgentLinkReply
}

/// 套接字底层的小工具：地址、选项、带总时限的读写。
enum AgentLinkSocket {
    static func address(for path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard bytes.count < AgentLinkPaths.socketPathLimit else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        return address
    }

    static func prepare(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func setTimeout(_ fd: Int32, option: Int32, seconds: TimeInterval) {
        let clamped = max(0.001, seconds)
        var value = timeval(
            tv_sec: Int(clamped),
            tv_usec: Int32((clamped - Double(Int(clamped))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    enum LineRead: Equatable {
        case line(Data)
        case tooLarge
        case closedOrTimedOut
    }

    /// 读一行（不含换行）。超过 `limit` 字节、总时限到或对端关闭都算失败。
    static func readLine(_ fd: Int32, limit: Int, timeout: TimeInterval) -> LineRead {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if buffer.count > limit { return .tooLarge }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .closedOrTimedOut }
            setTimeout(fd, option: SO_RCVTIMEO, seconds: remaining)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                // 只检查本次到达的数据；过去的buffer已确认无换行，不再重复扫描。
                if let newline = chunk.prefix(count).firstIndex(of: 0x0A) {
                    guard newline <= limit - buffer.count else { return .tooLarge }
                    buffer.append(chunk, count: newline)
                    return .line(buffer)
                }
                guard count <= limit - buffer.count else { return .tooLarge }
                buffer.append(chunk, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return .closedOrTimedOut
            }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data, timeout: TimeInterval) -> Bool {
        setTimeout(fd, option: SO_SNDTIMEO, seconds: timeout)
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    static func fileType(atPath path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }
}

/// 应用内的本机查询服务：Unix 域套接字，只有当前用户能连，带令牌鉴权，一问一答。
final class AgentLinkServer {
    /// 整轨译文可能超过旧 256 KB；仍有固定上限，防止四个连接无限占用内存。
    static let maxRequestBytes = 32 * 1024 * 1024
    static let maxConnections = 4
    static let readTimeout: TimeInterval = 2
    static let writeTimeout: TimeInterval = 10

    enum StartResult: Equatable {
        case started
        case refused(String)
    }

    private struct OwnedFile {
        let device: dev_t
        let inode: ino_t
    }

    private let paths: AgentLinkPaths
    private let provider: AgentLinkQueryProvider
    private let log: (String) -> Void
    private let acceptQueue = DispatchQueue(label: "seesee.agent-link.accept")
    private let connectionQueue = DispatchQueue(label: "seesee.agent-link.connection", attributes: .concurrent)
    private let lock = NSLock()
    private var activeConnections = 0
    private var source: DispatchSourceRead?
    private var ownedSocket: OwnedFile?
    private var ownedToken: OwnedFile?
    private var token = ""

    init(paths: AgentLinkPaths, provider: AgentLinkQueryProvider, log: @escaping (String) -> Void) {
        self.paths = paths
        self.provider = provider
        self.log = log
    }

    func start() -> StartResult {
        guard source == nil else { return .started }
        let socketPath = paths.socket.path
        guard socketPath.utf8.count < AgentLinkPaths.socketPathLimit else {
            return refuse("套接字路径太长（\(socketPath.utf8.count) 字节，上限 \(AgentLinkPaths.socketPathLimit - 1)），没有启动查询服务：\(socketPath)")
        }
        if let reason = prepareDirectory() {
            return refuse(reason)
        }
        switch AgentLinkSocket.fileType(atPath: socketPath) {
        case nil:
            break
        case S_IFSOCK?:
            // 上次没清掉的套接字：只有确认是套接字才删。
            guard unlink(socketPath) == 0 || errno == ENOENT else {
                return refuse("旧套接字删不掉（errno \(errno)），没有启动查询服务：\(socketPath)")
            }
        default:
            return refuse("\(socketPath) 不是套接字，原样保留，没有启动查询服务")
        }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return refuse("建不了套接字（errno \(errno)）") }
        AgentLinkSocket.prepare(listener)
        guard var address = AgentLinkSocket.address(for: socketPath) else {
            close(listener)
            return refuse("套接字路径太长，没有启动查询服务：\(socketPath)")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(listener)
            return refuse("绑定套接字失败（errno \(code)），没有启动查询服务：\(socketPath)")
        }
        // 目录已是 0700，这里再把套接字本身收紧到 0600。
        guard chmod(socketPath, 0o600) == 0, listen(listener, 16) == 0,
              let socketIdentity = Self.identity(atPath: socketPath, type: S_IFSOCK) else {
            close(listener)
            unlink(socketPath)
            return refuse("设置套接字失败（errno \(errno)），没有启动查询服务")
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

        let newToken = AgentLinkToken.generate()
        guard let tokenIdentity = writeToken(newToken) else {
            close(listener)
            unlink(socketPath)
            return refuse("写不了令牌文件（errno \(errno)），没有启动查询服务")
        }

        token = newToken
        ownedSocket = socketIdentity
        ownedToken = tokenIdentity
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPending(listener)
        }
        source.setCancelHandler {
            close(listener)
        }
        self.source = source
        source.resume()
        log("查询服务已启动：\(socketPath)")
        return .started
    }

    /// 关闭监听并删掉自己创建的套接字和令牌；不是自己创建的同名文件不动。
    func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        if let ownedSocket, Self.identity(atPath: paths.socket.path, type: S_IFSOCK).map({ $0.device == ownedSocket.device && $0.inode == ownedSocket.inode }) == true {
            unlink(paths.socket.path)
        }
        if let ownedToken,
           Self.identity(atPath: paths.token.path, type: S_IFREG).map({ $0.device == ownedToken.device && $0.inode == ownedToken.inode }) == true,
           (try? String(contentsOf: paths.token, encoding: .utf8)) == token {
            unlink(paths.token.path)
        }
        ownedSocket = nil
        ownedToken = nil
        log("查询服务已停止")
    }

    // MARK: - 启动准备

    private func refuse(_ reason: String) -> StartResult {
        log(reason)
        return .refused(reason)
    }

    /// 目录必须是本用户拥有的真实目录（不是符号链接），权限收紧到 0700。
    private func prepareDirectory() -> String? {
        let directoryPath = paths.directory.path
        let parent = paths.directory.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            return "建不了应用数据目录，没有启动查询服务：\(parent.path)"
        }
        if AgentLinkSocket.fileType(atPath: directoryPath) == nil {
            guard mkdir(directoryPath, 0o700) == 0 || errno == EEXIST else {
                return "建不了查询目录（errno \(errno)），没有启动查询服务：\(directoryPath)"
            }
        }
        var info = stat()
        guard lstat(directoryPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            return "\(directoryPath) 不是目录，原样保留，没有启动查询服务"
        }
        guard info.st_uid == getuid() else {
            return "\(directoryPath) 不属于当前用户，没有启动查询服务"
        }
        guard chmod(directoryPath, 0o700) == 0 else {
            return "收紧查询目录权限失败（errno \(errno)），没有启动查询服务"
        }
        return nil
    }

    /// 先以 0600 建临时文件写入，再原子改名成令牌文件，不留下权限宽松的中间状态。
    private func writeToken(_ value: String) -> OwnedFile? {
        let temporary = paths.directory
            .appendingPathComponent(".token-\(getpid())-\(AgentLinkToken.generate().prefix(8))", isDirectory: false)
            .path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let data = Data(value.utf8)
        let written = fchmod(fd, 0o600) == 0
            && data.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) == raw.count }
            && fsync(fd) == 0
        close(fd)
        guard written, rename(temporary, paths.token.path) == 0 else {
            unlink(temporary)
            return nil
        }
        return Self.identity(atPath: paths.token.path, type: S_IFREG)
    }

    private static func identity(atPath path: String, type: mode_t) -> OwnedFile? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == type else { return nil }
        return OwnedFile(device: info.st_dev, inode: info.st_ino)
    }

    // MARK: - 连接

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            AgentLinkSocket.prepare(client)
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)

            var peerUID = uid_t.max
            var peerGID = gid_t.max
            let knownPeer = getpeereid(client, &peerUID, &peerGID) == 0
            guard AgentLinkPeerPolicy.allows(peerUID: knownPeer ? peerUID : nil, ownUID: getuid()) else {
                close(client)
                continue
            }
            guard reserveConnection() else {
                close(client)
                continue
            }
            let expected = token
            connectionQueue.async { [weak self] in
                self?.serve(client, expectedToken: expected)
                close(client)
                self?.releaseConnection()
            }
        }
    }

    private func reserveConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < Self.maxConnections else { return false }
        activeConnections += 1
        return true
    }

    private func releaseConnection() {
        lock.lock()
        activeConnections -= 1
        lock.unlock()
    }

    private func serve(_ client: Int32, expectedToken: String) {
        guard case .line(let line) = AgentLinkSocket.readLine(
            client,
            limit: Self.maxRequestBytes,
            timeout: Self.readTimeout
        ) else { return }
        let reply: AgentLinkReply
        switch AgentLinkRequest.parse(line, expectedToken: expectedToken) {
        case .request(let request):
            reply = provider.answer(request)
        case .unauthorized:
            reply = .failure(code: AgentLinkReply.unauthorized, message: nil)
        case .badRequest:
            reply = .failure(code: AgentLinkReply.badRequest, message: nil)
        }
        _ = AgentLinkSocket.writeAll(client, reply.jsonLine(), timeout: Self.writeTimeout)
    }
}

/// 桥接进程一侧：每次现读令牌、现连套接字，问一次答一次。
enum AgentLinkClient {
    enum Outcome {
        case reply(AgentLinkReply)
        /// 令牌文件不存在或套接字连不上。
        case notRunning
        /// 套接字路径上是别的类型的文件，应用因此没有启动查询服务。
        case occupied(String)
        case failed(String)
    }

    static let maxReplyBytes = 64 * 1024 * 1024

    static func send(_ request: AgentLinkRequest, paths: AgentLinkPaths, timeout: TimeInterval) -> Outcome {
        let socketPath = paths.socket.path
        switch AgentLinkSocket.fileType(atPath: socketPath) {
        case nil:
            return .notRunning
        case S_IFSOCK?:
            break
        default:
            return .occupied(socketPath)
        }
        let resolvedToken: String
        if let token = request.token {
            resolvedToken = token
        } else {
            guard let stored = try? String(contentsOf: paths.token, encoding: .utf8) else { return .notRunning }
            resolvedToken = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolvedToken.isEmpty else { return .notRunning }
        }
        guard var address = AgentLinkSocket.address(for: socketPath) else {
            return .failed("套接字路径太长：\(socketPath)")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("建不了套接字（errno \(errno)）") }
        defer { close(fd) }
        AgentLinkSocket.prepare(fd)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            if code == ECONNREFUSED || code == ENOENT { return .notRunning }
            return .failed("连不上 seesee（errno \(code)）")
        }
        guard AgentLinkSocket.writeAll(fd, request.jsonLine(token: resolvedToken), timeout: timeout) else {
            return .failed("发送查询失败")
        }
        guard case .line(let line) = AgentLinkSocket.readLine(fd, limit: maxReplyBytes, timeout: timeout) else {
            return .failed("seesee 没有在 \(Int(timeout)) 秒内回答，或回答前断开了连接")
        }
        guard let reply = AgentLinkReply.parse(line) else {
            return .failed("seesee 的回答不是约定的格式")
        }
        return .reply(reply)
    }
}
