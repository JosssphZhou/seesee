import Darwin
import Foundation

enum LanSRT {
    static func toVTT(_ raw: String) -> String {
        var text = raw
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = text.components(separatedBy: "\n\n")
        var cues: [String] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let tsIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timestamp = convertTimestampLine(lines[tsIndex])
            let payload = Array(lines[(tsIndex + 1)...])
            guard !payload.isEmpty else { continue }
            cues.append(timestamp + "\n" + payload.joined(separator: "\n"))
        }
        var output = "WEBVTT\n"
        if !cues.isEmpty {
            output += "\n" + cues.joined(separator: "\n\n") + "\n"
        }
        return output
    }

    private static func convertTimestampLine(_ line: String) -> String {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else {
            return line.replacingOccurrences(of: ",", with: ".")
        }
        let start = normalizeTime(parts[0])
        let rest = parts[1].trimmingCharacters(in: .whitespaces)
        let endToken = rest.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? rest
        return "\(start) --> \(normalizeTime(endToken))"
    }

    private static func normalizeTime(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    }
}

struct LanCatalogItem: Equatable {
    var id: UUID
    var title: String
    var durationText: String
    var hasThumbnail: Bool
    var hasChineseSubtitle: Bool
}

struct LanLibrary {
    var items: [LanCatalogItem]
    var videos: [UUID: String]
    var thumbnails: [UUID: String]
    var subtitles: [UUID: String]
    /// 片库根目录（应用的媒体目录）。只提供真实路径落在它之内的文件。
    var mediaRoot: URL

    static func load(queueJSON: Data, mediaRoot: URL, fileExists: (String) -> Bool) throws -> LanLibrary {
        let rows = try JSONDecoder().decode([QueueRow].self, from: queueJSON)
        var items: [LanCatalogItem] = []
        var videos: [UUID: String] = [:]
        var thumbnails: [UUID: String] = [:]
        var subtitles: [UUID: String] = [:]
        for row in rows {
            guard row.state == "ready",
                  let path = nonempty(row.localFilePath),
                  fileExists(path)
            else { continue }
            let thumb = nonempty(row.thumbnailFilePath)
            let subtitle = nonempty(row.subtitleFilePath)
            let hasThumb = thumb.map(fileExists) ?? false
            let hasZh = subtitle.map { isChineseSRT($0) && fileExists($0) } ?? false
            items.append(
                LanCatalogItem(
                    id: row.id,
                    title: row.title.isEmpty ? "未命名" : row.title,
                    durationText: formatDuration(row.duration),
                    hasThumbnail: hasThumb,
                    hasChineseSubtitle: hasZh
                )
            )
            videos[row.id] = path
            if hasThumb, let thumb { thumbnails[row.id] = thumb }
            if hasZh, let subtitle { subtitles[row.id] = subtitle }
        }
        return LanLibrary(
            items: items,
            videos: videos,
            thumbnails: thumbnails,
            subtitles: subtitles,
            mediaRoot: mediaRoot
        )
    }

    static func load(queueFile: URL, mediaRoot: URL) throws -> LanLibrary {
        let data = try Data(contentsOf: queueFile)
        return try load(queueJSON: data, mediaRoot: mediaRoot) { LanFile.isServable($0, inside: mediaRoot) }
    }

    func videoURL(_ id: UUID) -> URL? {
        videos[id].map { URL(fileURLWithPath: $0) }
    }

    func thumbnailURL(_ id: UUID) -> URL? {
        thumbnails[id].map { URL(fileURLWithPath: $0) }
    }

    func subtitleURL(_ id: UUID) -> URL? {
        subtitles[id].map { URL(fileURLWithPath: $0) }
    }

    func item(id: UUID) -> LanCatalogItem? {
        items.first { $0.id == id }
    }

    private struct QueueRow: Decodable {
        var id: UUID
        var title: String
        var duration: Double?
        var state: String
        var localFilePath: String?
        var thumbnailFilePath: String?
        var subtitleFilePath: String?
    }
}

/// 片库只提供片库根目录里的文件：解开所有符号链接后的真实路径必须落在根目录的真实路径之内，
/// 否则一律当作不存在。加载队列和响应请求都走这里，判断只有一处。
enum LanFile {
    static func isServable(_ path: String, inside root: URL) -> Bool {
        guard let opened = openServable(path, inside: root) else { return false }
        try? opened.handle.close()
        return true
    }

    /// 打开解析出的真实路径时用 O_NOFOLLOW，判断之后文件被换成链接也打不开；
    /// 打开后再取文件的真实路径做同一个范围判断，挡住判断之后上级目录被换成链接。
    static func openServable(_ path: String, inside root: URL) -> (handle: FileHandle, length: UInt64)? {
        guard let rootPath = realPath(root.path),
              let target = realPath(path),
              isInside(target, root: rootPath)
        else { return nil }
        let fd = open(target, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let opened = realPath(of: fd), isInside(opened, root: rootPath)
        else {
            close(fd)
            return nil
        }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), UInt64(info.st_size))
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func realPath(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }
}

enum LanAccess {
    static func loadOrCreate(at url: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let existing = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !existing.isEmpty {
                try tightenPermissions(url)
                return existing
            }
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try Data(token.utf8).write(to: url, options: .atomic)
        try tightenPermissions(url)
        return token
    }

    static func provided(_ value: String?, matches expected: String) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count == expected.utf8.count else { return false }
        return timingSafeEqual(trimmed, expected)
    }

    private static func tightenPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func timingSafeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8)
        let b = Array(right.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices {
            diff |= a[index] ^ b[index]
        }
        return diff == 0
    }
}

enum LanRoute: Equatable {
    case home
    case watch(UUID)
    case video(UUID)
    case subtitle(UUID)
    case thumb(UUID)

    static func parse(_ rawPath: String) -> LanRoute? {
        let path = decodePath(rawPath)
        if path.contains("..") { return nil }
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if parts.isEmpty || parts == ["index.html"] {
            return .home
        }
        if parts.count == 1 {
            return nil
        }
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "watch":
            return .watch(id)
        case "video":
            return .video(id)
        case "subtitle":
            return .subtitle(id)
        case "thumb":
            return .thumb(id)
        default:
            return nil
        }
    }

    private static func decodePath(_ raw: String) -> String {
        var path = raw
        if let q = path.firstIndex(of: "?") {
            path = String(path[..<q])
        }
        return path.removingPercentEncoding ?? path
    }
}

enum LanByteRange: Equatable {
    case full
    case partial(start: UInt64, endInclusive: UInt64)
    case unsatisfiable

    static func parse(_ header: String?, fileLength: UInt64) -> LanByteRange {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return .full }
        guard fileLength > 0 else { return .unsatisfiable }
        let spec = String(header.dropFirst(6)).split(separator: ",")[0]
            .trimmingCharacters(in: .whitespaces)
        if spec.hasPrefix("-") {
            guard let suffix = UInt64(spec.dropFirst()), suffix > 0 else { return .unsatisfiable }
            let length = min(suffix, fileLength)
            return .partial(start: fileLength - length, endInclusive: fileLength - 1)
        }
        let sides = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let start = UInt64(sides[0]), start < fileLength else { return .unsatisfiable }
        if sides.count == 1 || sides[1].isEmpty {
            return .partial(start: start, endInclusive: fileLength - 1)
        }
        guard let end = UInt64(sides[1]) else { return .unsatisfiable }
        if end < start { return .unsatisfiable }
        return .partial(start: start, endInclusive: min(end, fileLength - 1))
    }
}

struct LanHTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var remoteHost: String
}

struct LanHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
    var file: FileSlice?

    struct FileSlice {
        var url: URL
        var root: URL
        var offset: UInt64
        var length: UInt64
    }

    static func text(_ status: Int, _ body: String, type: String = "text/plain; charset=utf-8") -> LanHTTPResponse {
        LanHTTPResponse(
            status: status,
            headers: [
                "Content-Type": type,
                "Content-Length": "\(body.utf8.count)",
                "Cache-Control": "no-store"
            ],
            body: Data(body.utf8),
            file: nil
        )
    }

    static func html(_ status: Int, _ body: String) -> LanHTTPResponse {
        text(status, body, type: "text/html; charset=utf-8")
    }
}

enum LanHTTP {
    static func handle(_ request: LanHTTPRequest, token: String, library: LanLibrary) -> LanHTTPResponse {
        handle(request, token: token, loadLibrary: { library })
    }

    /// 先核对来源和访问码，再限定只读方法，最后才解析队列，未授权请求不触发读队列。
    static func handle(
        _ request: LanHTTPRequest,
        token: String,
        loadLibrary: () throws -> LanLibrary
    ) -> LanHTTPResponse {
        guard LanNet.isPrivateIPv4(request.remoteHost) else {
            return LanHTTPResponse.text(403, "拒绝")
        }
        let provided = request.query["k"] ?? cookieValue(request.headers["cookie"], name: "lan")
        guard LanAccess.provided(provided, matches: token) else {
            return LanHTTPResponse.text(403, "需要访问码")
        }
        let method = request.method.uppercased()
        guard method == "GET" || method == "HEAD" else {
            var response = LanHTTPResponse.text(405, "只能读取")
            response.headers["Allow"] = "GET, HEAD"
            return response
        }
        guard let route = LanRoute.parse(request.path) else {
            return LanHTTPResponse.text(404, "没有这部片")
        }
        let library: LanLibrary
        do {
            library = try loadLibrary()
        } catch {
            return LanHTTPResponse.text(500, "读不了队列")
        }
        var response = routed(route, request: request, token: token, library: library)
        if method == "HEAD" {
            response.file = nil
            response.body = Data()
        }
        return response
    }

    private static func routed(
        _ route: LanRoute,
        request: LanHTTPRequest,
        token: String,
        library: LanLibrary
    ) -> LanHTTPResponse {
        switch route {
        case .home:
            return withCookie(LanHTTPResponse.html(200, LanPages.home(library.items, token: token)), token: token)
        case .watch(let id):
            guard let item = library.item(id: id) else {
                return LanHTTPResponse.text(404, "没有这部片")
            }
            return withCookie(LanHTTPResponse.html(200, LanPages.watch(item, token: token)), token: token)
        case .video(let id):
            return fileResponse(request, url: library.videoURL(id), root: library.mediaRoot, type: "video/mp4")
        case .thumb(let id):
            guard let url = library.thumbnailURL(id) else {
                return LanHTTPResponse.text(404, "没有封面")
            }
            return fileResponse(request, url: url, root: library.mediaRoot, type: mimeType(url))
        case .subtitle(let id):
            guard let url = library.subtitleURL(id) else {
                return LanHTTPResponse.text(404, "没有字幕")
            }
            do {
                guard let opened = LanFile.openServable(url.path, inside: library.mediaRoot) else {
                    return LanHTTPResponse.text(404, "没有字幕")
                }
                defer { try? opened.handle.close() }
                guard var raw = String(data: try opened.handle.readToEnd() ?? Data(), encoding: .utf8) else {
                    return LanHTTPResponse.text(404, "没有字幕")
                }
                if raw.hasPrefix("\u{FEFF}") { raw.removeFirst() }
                let vtt = url.path.lowercased().hasSuffix(".vtt") ? (raw.hasPrefix("WEBVTT") ? raw : "WEBVTT\n\n" + raw) : LanSRT.toVTT(raw)
                let data = Data(vtt.utf8)
                return LanHTTPResponse(
                    status: 200,
                    headers: [
                        "Content-Type": "text/vtt; charset=utf-8",
                        "Content-Length": "\(data.count)",
                        "Cache-Control": "no-store"
                    ],
                    body: data,
                    file: nil
                )
            } catch {
                return LanHTTPResponse.text(404, "没有字幕")
            }
        }
    }

    private static func fileResponse(_ request: LanHTTPRequest, url: URL?, root: URL, type: String) -> LanHTTPResponse {
        guard let url, let opened = LanFile.openServable(url.path, inside: root) else {
            return LanHTTPResponse.text(404, "没有这部片")
        }
        try? opened.handle.close()
        let length = opened.length
        let range = LanByteRange.parse(header(request.headers, "range"), fileLength: length)
        var response: LanHTTPResponse
        switch range {
        case .full:
            response = LanHTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": type,
                    "Content-Length": "\(length)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "private, max-age=3600"
                ],
                body: Data(),
                file: LanHTTPResponse.FileSlice(url: url, root: root, offset: 0, length: length)
            )
        case .partial(let start, let end):
            let slice = end - start + 1
            response = LanHTTPResponse(
                status: 206,
                headers: [
                    "Content-Type": type,
                    "Content-Length": "\(slice)",
                    "Content-Range": "bytes \(start)-\(end)/\(length)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "private, max-age=3600"
                ],
                body: Data(),
                file: LanHTTPResponse.FileSlice(url: url, root: root, offset: start, length: slice)
            )
        case .unsatisfiable:
            response = LanHTTPResponse(
                status: 416,
                headers: [
                    "Content-Range": "bytes */\(length)",
                    "Content-Length": "0"
                ],
                body: Data(),
                file: nil
            )
        }
        return response
    }

    private static func withCookie(_ response: LanHTTPResponse, token: String) -> LanHTTPResponse {
        var next = response
        next.headers["Set-Cookie"] = "lan=\(token); Path=/; HttpOnly; SameSite=Lax"
        return next
    }

    private static func header(_ headers: [String: String], _ name: String) -> String? {
        let key = name.lowercased()
        return headers.first { $0.key.lowercased() == key }?.value
    }

    private static func cookieValue(_ cookie: String?, name: String) -> String? {
        guard let cookie else { return nil }
        for part in cookie.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pair.count == 2, pair[0] == name {
                return pair[1]
            }
        }
        return nil
    }

    private static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "webp":
            return "image/webp"
        default:
            return "image/jpeg"
        }
    }
}

enum LanPages {
    static func home(_ items: [LanCatalogItem], token: String) -> String {
        let cards: String
        if items.isEmpty {
            cards = "<p class=\"empty\">还没有下完的片</p>"
        } else {
            cards = "<ul class=\"grid\">" + items.map { item in
                let href = "/watch/\(item.id.uuidString)?k=\(token)"
                let poster: String
                if item.hasThumbnail {
                    poster = "<img src=\"/thumb/\(item.id.uuidString)?k=\(token)\" alt=\"\">"
                } else {
                    poster = "<div class=\"ph\"></div>"
                }
                return """
                <li><a href="\(href)">\(poster)<div class="meta"><strong>\(escape(item.title))</strong><span>\(escape(item.durationText))</span></div></a></li>
                """
            }.joined() + "</ul>"
        }
        return document(title: "片库", body: "<h1>片库</h1>\(cards)")
    }

    static func watch(_ item: LanCatalogItem, token: String) -> String {
        let track: String
        if item.hasChineseSubtitle {
            track = "<track kind=\"subtitles\" srclang=\"zh\" label=\"中文\" src=\"/subtitle/\(item.id.uuidString)?k=\(token)\" default>"
        } else {
            track = ""
        }
        let poster = item.hasThumbnail ? " poster=\"/thumb/\(item.id.uuidString)?k=\(token)\"" : ""
        let body = """
        <p class="back"><a href="/?k=\(token)">片库</a></p>
        <h1>\(escape(item.title))</h1>
        <video controls playsinline preload="metadata"\(poster)>
        <source src="/video/\(item.id.uuidString)?k=\(token)" type="video/mp4">
        \(track)
        </video>
        """
        return document(title: item.title, body: body)
    }

    private static func document(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: dark; }
        * { box-sizing: border-box; }
        body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; background: #111; color: #f3f3f3; padding: max(20px, env(safe-area-inset-top)) max(20px, env(safe-area-inset-right)) max(24px, env(safe-area-inset-bottom)) max(20px, env(safe-area-inset-left)); }
        h1 { font-size: 1.4rem; font-weight: 600; margin: 0 0 1rem; }
        a { color: inherit; text-decoration: none; }
        .back { margin: 0 0 0.8rem; }
        .back a { display: inline-flex; min-height: 44px; align-items: center; color: #9ad; }
        .grid { list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 16px; }
        .grid a { display: flex; flex-direction: column; min-height: 44px; background: #1c1c1e; border-radius: 14px; overflow: hidden; }
        .grid img, .ph { width: 100%; aspect-ratio: 16/9; object-fit: cover; background: #2c2c2e; display: block; }
        .meta { padding: 12px 14px 16px; display: flex; flex-direction: column; gap: 6px; }
        .meta strong { font-size: 1rem; line-height: 1.35; }
        .meta span { color: #aaa; font-size: 0.9rem; }
        .empty { color: #aaa; }
        video { width: 100%; max-height: 78vh; background: #000; border-radius: 12px; }
        @media (orientation: landscape) { video { max-height: 86vh; } }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

enum LanNet {
    static func defaultHosts() -> [String] {
        var hosts = ["127.0.0.1"]
        if let lan = lanIPv4(), !hosts.contains(lan) {
            hosts.append(lan)
        }
        return hosts
    }

    static func lanIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var preferred: String?
        var fallback: String?
        var current = ifaddr
        while let pointer = current {
            let interface = pointer.pointee
            current = interface.ifa_next
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            if name == "lo0" { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: host)
            guard isPrivateIPv4(ip), !ip.hasPrefix("127.") else { continue }
            if name.hasPrefix("en") {
                preferred = ip
                break
            }
            fallback = ip
        }
        return preferred ?? fallback
    }

    /// 监听地址只允许回环和 RFC1918 私网段；0.0.0.0、公网、链路本地一律拒绝。
    static func isAllowedBindHost(_ host: String) -> Bool {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return false }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch parts[0] {
        case 127, 10:
            return true
        case 172:
            return (16...31).contains(parts[1])
        case 192:
            return parts[1] == 168
        default:
            return false
        }
    }

    static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 127 { return true }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }
}

final class LanPlayerServer {
    private var sockets: [Int32] = []
    private var running = false
    private let acceptQueue = DispatchQueue(label: "seesee.lan-player.accept")
    private let workQueue = DispatchQueue(label: "seesee.lan-player.work", attributes: .concurrent)
    private let handler: (LanHTTPRequest) -> LanHTTPResponse
    private(set) var port: UInt16

    init(port: UInt16, handler: @escaping (LanHTTPRequest) -> LanHTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func start(hosts: [String]) throws {
        if let rejected = hosts.first(where: { !LanNet.isAllowedBindHost($0) }) {
            throw NSError(
                domain: "LanPlayer",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "只能监听本机回环或局域网私有地址，拒绝 \(rejected)"]
            )
        }
        running = true
        var boundPort = port
        for host in hosts {
            let fd = try listenSocket(host: host, port: boundPort)
            if boundPort == 0 {
                boundPort = try socketPort(fd)
                port = boundPort
            }
            sockets.append(fd)
            let captured = fd
            acceptQueue.async { [weak self] in
                self?.acceptLoop(fd: captured)
            }
        }
        guard !sockets.isEmpty else {
            throw NSError(domain: "LanPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可监听的地址"])
        }
    }

    func stop() {
        running = false
        for fd in sockets {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        sockets.removeAll()
    }

    private func listenSocket(host: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "LanPlayer", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建套接字"])
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let converted = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard converted == 1 else {
            close(fd)
            throw NSError(domain: "LanPlayer", code: 3, userInfo: [NSLocalizedDescriptionKey: "地址无效"])
        }
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw NSError(domain: "LanPlayer", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法监听 \(host):\(port)"])
        }
        return fd
    }

    private func socketPort(_ fd: Int32) throws -> UInt16 {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                getsockname(fd, sock, &length)
            }
        }
        guard result == 0 else {
            throw NSError(domain: "LanPlayer", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法读取端口"])
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    private func acceptLoop(fd: Int32) {
        while running {
            var addr = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    accept(fd, sock, &length)
                }
            }
            if client < 0 {
                if !running { return }
                continue
            }
            var nosig: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            var addrCopy = addr.sin_addr
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addrCopy, &host, socklen_t(INET_ADDRSTRLEN))
            let remote = String(cString: host)
            workQueue.async { [weak self] in
                self?.serve(client: client, remote: remote)
            }
        }
    }

    private func serve(client: Int32, remote: String) {
        defer { close(client) }
        guard let headerData = readHeaders(fd: client) else { return }
        guard let request = parseRequest(headerData, remote: remote) else {
            writeResponse(fd: client, LanHTTPResponse.text(400, "无法解析"))
            return
        }
        let response = handler(request)
        writeResponse(fd: client, response)
    }

    private func readHeaders(fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let received = recv(fd, &buffer, buffer.count, 0)
            if received <= 0 { return data.isEmpty ? nil : data }
            data.append(contentsOf: buffer[0..<received])
            if data.range(of: Data([13, 10, 13, 10])) != nil { return data }
            if data.range(of: Data([10, 10])) != nil { return data }
        }
        return nil
    }

    private func parseRequest(_ data: Data, remote: String) -> LanHTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let pieces = normalized.components(separatedBy: "\n\n")
        let headerBlock = pieces.first ?? ""
        let lines = headerBlock.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return nil }
        let tokens = first.split(separator: " ")
        guard tokens.count >= 2 else { return nil }
        let method = String(tokens[0])
        let target = String(tokens[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let sep = line.firstIndex(of: ":") else { continue }
            let name = line[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                query[item.name] = value
            }
        }
        return LanHTTPRequest(
            method: method,
            path: components?.path ?? target,
            query: query,
            headers: headers,
            remoteHost: remote
        )
    }

    private func writeResponse(fd: Int32, _ response: LanHTTPResponse) {
        var header = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (name, value) in response.headers {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        writeAll(fd: fd, Data(header.utf8))
        if !response.body.isEmpty {
            writeAll(fd: fd, response.body)
        }
        if let file = response.file {
            writeFile(fd: fd, file)
        }
    }

    private func writeFile(fd: Int32, _ file: LanHTTPResponse.FileSlice) {
        guard let handle = LanFile.openServable(file.url.path, inside: file.root)?.handle else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: file.offset)
        } catch {
            return
        }
        var remaining = file.length
        while remaining > 0 {
            let chunk = Int(min(remaining, 64 * 1024))
            let data = handle.readData(ofLength: chunk)
            if data.isEmpty { break }
            writeAll(fd: fd, data)
            remaining -= UInt64(data.count)
        }
    }

    private func writeAll(fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(fd, base + sent, data.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }
}

final class LanPlayerRuntime {
    private let queueFile: URL
    private let mediaRoot: URL
    private let token: String
    private var server: LanPlayerServer?

    var port: UInt16 { server?.port ?? 0 }

    init(queueFile: URL, mediaRoot: URL, tokenFile: URL) throws {
        self.queueFile = queueFile
        self.mediaRoot = mediaRoot
        self.token = try LanAccess.loadOrCreate(at: tokenFile)
    }

    init(queueFile: URL, mediaRoot: URL, token: String) {
        self.queueFile = queueFile
        self.mediaRoot = mediaRoot
        self.token = token
    }

    func start(hosts: [String], port: UInt16) throws {
        let queueFile = self.queueFile
        let mediaRoot = self.mediaRoot
        let token = self.token
        let server = LanPlayerServer(port: port) { request in
            LanHTTP.handle(request, token: token) {
                try LanLibrary.load(queueFile: queueFile, mediaRoot: mediaRoot)
            }
        }
        try server.start(hosts: hosts)
        self.server = server
    }

    func stop() {
        server?.stop()
        server = nil
    }
}

func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func isChineseSRT(_ path: String) -> Bool {
    let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
    guard name.hasSuffix(".srt") else { return false }
    let stem = String(name.dropLast(4))
    return stem.hasSuffix(".zh")
        || stem.contains(".zh-")
        || stem.hasSuffix(".zh_hans")
        || stem.hasSuffix(".zh_hant")
}

func formatDuration(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite else { return "0:00" }
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remaining = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
        : String(format: "%d:%02d", minutes, remaining)
}
