import Foundation

@main
struct LanPlayerCheck {
    static func main() {
        checkSRTToVTT()
        checkCatalogListsOnlyExistingReady()
        checkAccessCode()
        checkTraversalRejected()
        checkMissingAccessCodeRejected()
        checkByteRange()
        checkHTTP()
        checkSymlinkEntriesRejected()
        checkParentDirectorySymlinkRejected()
        checkOutsideMediaRootRejected()
        checkBindRestrictedToPrivate()
        checkMethodsAndAuthOrder()
        print("lan_player_check=passed")
    }

    private static func checkSRTToVTT() {
        let srt = """
        \u{FEFF}1
        00:00:00,500 --> 00:00:03,000
        Hello world
        你好世界

        2
        00:00:03,000 --> 00:00:05,250
        Second line
        第二行
        """
        let vtt = LanSRT.toVTT(srt)
        precondition(vtt.hasPrefix("WEBVTT\n"), "VTT 必须以 WEBVTT 开头")
        precondition(!vtt.contains("\u{FEFF}"), "必须去掉 BOM")
        precondition(vtt.contains("00:00:00.500 --> 00:00:03.000"), "毫秒逗号必须改成点")
        precondition(vtt.contains("00:00:03.000 --> 00:00:05.250"), "第二条时间轴也要转换")
        precondition(!vtt.contains("00:00:00,500"), "VTT 里不得残留 SRT 逗号时间")
        precondition(vtt.contains("Hello world\n你好世界"), "双语两行必须保留")
        precondition(vtt.contains("Second line\n第二行"), "后续双语块必须保留")
    }

    private static func checkCatalogListsOnlyExistingReady() {
        let readyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let missingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let downloadingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let json = """
        [
          {
            "id": "\(readyID.uuidString)",
            "urlString": "https://example.com/a",
            "title": "能看的片",
            "author": "",
            "duration": 125.4,
            "addedAt": "2026-01-01T00:00:00Z",
            "state": "ready",
            "progress": 1,
            "progressLabel": "",
            "localFilePath": "/tmp/lan-player-ready.mp4",
            "thumbnailFilePath": "/tmp/lan-player-ready.jpg",
            "subtitleFilePath": "/tmp/lan-player-ready.zh.srt"
          },
          {
            "id": "\(missingID.uuidString)",
            "urlString": "https://example.com/b",
            "title": "文件没了",
            "author": "",
            "duration": 10,
            "addedAt": "2026-01-01T00:00:00Z",
            "state": "ready",
            "progress": 1,
            "progressLabel": "",
            "localFilePath": "/tmp/lan-player-missing.mp4",
            "thumbnailFilePath": "",
            "subtitleFilePath": ""
          },
          {
            "id": "\(downloadingID.uuidString)",
            "urlString": "https://example.com/c",
            "title": "还在下",
            "author": "",
            "duration": 10,
            "addedAt": "2026-01-01T00:00:00Z",
            "state": "downloading",
            "progress": 0.4,
            "progressLabel": "40%",
            "localFilePath": "/tmp/lan-player-partial.mp4",
            "thumbnailFilePath": "",
            "subtitleFilePath": ""
          }
        ]
        """.data(using: .utf8)!

        let existing: Set<String> = [
            "/tmp/lan-player-ready.mp4",
            "/tmp/lan-player-ready.jpg",
            "/tmp/lan-player-ready.zh.srt",
            "/tmp/lan-player-partial.mp4"
        ]
        let library = try! LanLibrary.load(queueJSON: json, mediaRoot: URL(fileURLWithPath: "/tmp")) { existing.contains($0) }
        precondition(library.items.count == 1, "只列出已完成且文件存在的条目")
        precondition(library.items[0].id == readyID)
        precondition(library.items[0].title == "能看的片")
        precondition(library.items[0].durationText == "2:05")
        precondition(library.items[0].hasThumbnail)
        precondition(library.items[0].hasChineseSubtitle)
        precondition(library.videoURL(readyID)?.path == "/tmp/lan-player-ready.mp4")
        precondition(library.videoURL(missingID) == nil)
        precondition(library.videoURL(downloadingID) == nil)
    }

    private static func checkAccessCode() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lan-player-token-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lan-player-access-code")
        let first = try! LanAccess.loadOrCreate(at: file)
        let second = try! LanAccess.loadOrCreate(at: file)
        precondition(!first.isEmpty, "首次启动必须生成访问码")
        precondition(first == second, "再次启动必须复用已有访问码")
        let perms = try! FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        precondition(perms.uint16Value & 0o077 == 0, "访问码文件权限必须是 600")
        precondition(LanAccess.provided("  ", matches: first) == false)
        precondition(LanAccess.provided(nil, matches: first) == false)
        precondition(LanAccess.provided("nope", matches: first) == false)
        precondition(LanAccess.provided(first, matches: first))
    }

    private static func checkTraversalRejected() {
        let paths = [
            "/video/../../etc/passwd",
            "/../queue.json",
            "/video/%2e%2e/%2e%2e/etc/passwd",
            "/watch/..%2F..%2Fetc/passwd",
            "/video/not-a-uuid"
        ]
        for path in paths {
            precondition(LanRoute.parse(path) == nil, "穿越或非法路径必须拒绝：\(path)")
        }
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        precondition(LanRoute.parse("/video/\(id.uuidString)") == .video(id))
        precondition(LanRoute.parse("/watch/\(id.uuidString.lowercased())") == .watch(id))
    }

    private static func checkMissingAccessCodeRejected() {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let library = LanLibrary(
            items: [LanCatalogItem(
                id: id,
                title: "片",
                durationText: "1:00",
                hasThumbnail: false,
                hasChineseSubtitle: false
            )],
            videos: [id: "/tmp/x.mp4"],
            thumbnails: [:],
            subtitles: [:],
            mediaRoot: URL(fileURLWithPath: "/tmp")
        )
        let request = LanHTTPRequest(
            method: "GET",
            path: "/",
            query: [:],
            headers: [:],
            remoteHost: "127.0.0.1"
        )
        let response = LanHTTP.handle(request, token: "secret-code", library: library)
        precondition(response.status == 403, "没带访问码必须 403")
        precondition(!(String(data: response.body, encoding: .utf8) ?? "").contains("secret-code"))
    }

    private static func checkByteRange() {
        precondition(LanByteRange.parse(nil, fileLength: 1000) == .full)
        precondition(
            LanByteRange.parse("bytes=0-99", fileLength: 1000) == .partial(start: 0, endInclusive: 99)
        )
        precondition(
            LanByteRange.parse("bytes=500-", fileLength: 1000) == .partial(start: 500, endInclusive: 999)
        )
        precondition(
            LanByteRange.parse("bytes=-100", fileLength: 1000) == .partial(start: 900, endInclusive: 999)
        )
        precondition(LanByteRange.parse("bytes=2000-2001", fileLength: 1000) == .unsatisfiable)
    }

    private static func checkHTTP() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lan-player-http-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let video = root.appendingPathComponent("\(id.uuidString).mp4")
        let thumb = root.appendingPathComponent("\(id.uuidString).jpg")
        let subtitle = root.appendingPathComponent("\(id.uuidString).zh.srt")
        let payload = Data((0..<1000).map { UInt8($0 % 256) })
        try! payload.write(to: video)
        try! Data([0xFF, 0xD8, 0xFF]).write(to: thumb)
        try! Data("1\n00:00:00,500 --> 00:00:01,000\nHi\n你好\n".utf8).write(to: subtitle)
        let secret = root.appendingPathComponent("outside.txt")
        try! Data("should-not-read".utf8).write(to: secret)

        let json = """
        [
          {
            "id": "\(id.uuidString)",
            "urlString": "https://example.com/a",
            "title": "测试片",
            "author": "",
            "duration": 12,
            "addedAt": "2026-01-01T00:00:00Z",
            "state": "ready",
            "progress": 1,
            "progressLabel": "",
            "localFilePath": "\(video.path)",
            "thumbnailFilePath": "\(thumb.path)",
            "subtitleFilePath": "\(subtitle.path)"
          }
        ]
        """.data(using: .utf8)!
        let queue = root.appendingPathComponent("queue.json")
        try! json.write(to: queue)
        let tokenFile = root.appendingPathComponent("token")
        try! Data("test-token-value".utf8).write(to: tokenFile)

        let runtime = try! LanPlayerRuntime(queueFile: queue, mediaRoot: root, tokenFile: tokenFile)
        try! runtime.start(hosts: ["127.0.0.1"], port: 0)
        defer { runtime.stop() }
        let port = runtime.port
        let token = "test-token-value"
        let session = URLSession(configuration: .ephemeral)

        let forbidden = data(session, url("http://127.0.0.1:\(port)/"))
        precondition(forbidden.status == 403, "HTTP 没带访问码必须 403")

        let home = data(session, url("http://127.0.0.1:\(port)/?k=\(token)"))
        precondition(home.status == 200)
        let homeHTML = String(data: home.body, encoding: .utf8) ?? ""
        precondition(homeHTML.contains("测试片"))
        precondition(homeHTML.contains("0:12"))

        let rangeReq = NSMutableURLRequest(url: url("http://127.0.0.1:\(port)/video/\(id.uuidString)?k=\(token)"))
        rangeReq.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let ranged = data(session, rangeReq as URLRequest)
        precondition(ranged.status == 206, "Range 必须返回 206")
        precondition(ranged.body == Data(payload[10...19]))
        precondition(ranged.header("Content-Range") == "bytes 10-19/1000")
        precondition(ranged.header("Content-Type") == "video/mp4")

        let vtt = data(session, url("http://127.0.0.1:\(port)/subtitle/\(id.uuidString)?k=\(token)"))
        precondition(vtt.status == 200)
        precondition(vtt.header("Content-Type")?.contains("text/vtt") == true)
        let vttText = String(data: vtt.body, encoding: .utf8) ?? ""
        precondition(vttText.contains("WEBVTT"))
        precondition(vttText.contains("00:00:00.500 --> 00:00:01.000"))
        precondition(vttText.contains("Hi\n你好"))

        let leaked = data(session, url("http://127.0.0.1:\(port)/video/../../outside.txt?k=\(token)"))
        precondition(leaked.status == 404 || leaked.status == 403)
        precondition(String(data: leaked.body, encoding: .utf8)?.contains("should-not-read") != true)
    }

    /// 片库根目录 media 里放一部正常片；outside 是片库外的目录，放着不该被读到的内容。
    /// 系统临时目录本身在 /var → /private/var 链接之下，顺带验证片库根目录自身经过链接也照常工作。
    private struct MediaRootFixture {
        let root: URL
        let media: URL
        let outside: URL
        let normalVideo: URL

        static let secret = "SECRET-OUTSIDE-MEDIA-ROOT"

        init(_ name: String) {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            media = root.appendingPathComponent("media", isDirectory: true)
            outside = root.appendingPathComponent("outside", isDirectory: true)
            try! fm.createDirectory(at: media, withIntermediateDirectories: true)
            try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
            // 比链接本身长，确认不会按链接长度截出前段。
            let secretText = Self.secret + " " + String(repeating: "x", count: 200)
            try! Data(secretText.utf8).write(to: outside.appendingPathComponent("movie.mp4"))
            try! Data(secretText.utf8).write(to: outside.appendingPathComponent("movie.jpg"))
            try! Data("1\n00:00:00,000 --> 00:00:01,000\n\(Self.secret)\n".utf8)
                .write(to: outside.appendingPathComponent("movie.zh.srt"))
            normalVideo = media.appendingPathComponent("normal.mp4")
            try! Data("normal-video".utf8).write(to: normalVideo)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// 同一套断言：登记的视频、封面、字幕路径解析后不在片库根目录之内，
    /// 加载时不列出，读取时（模拟加载之后才被换掉）404，真实 HTTP 也拿不到内容；片库内的正常片照常播放。
    private static func assertOutsideRejected(
        _ fixture: MediaRootFixture,
        video: String,
        thumb: String,
        subtitle: String,
        label: String
    ) {
        let rejectedID = UUID()
        let normalID = UUID()
        let json = """
        [
          {
            "id": "\(rejectedID.uuidString)",
            "title": "片库外",
            "duration": 5,
            "state": "ready",
            "localFilePath": "\(video)",
            "thumbnailFilePath": "\(thumb)",
            "subtitleFilePath": "\(subtitle)"
          },
          {
            "id": "\(normalID.uuidString)",
            "title": "正常片",
            "duration": 5,
            "state": "ready",
            "localFilePath": "\(fixture.normalVideo.path)",
            "thumbnailFilePath": "\(thumb)",
            "subtitleFilePath": "\(subtitle)"
          }
        ]
        """.data(using: .utf8)!
        let queue = fixture.root.appendingPathComponent("queue.json")
        try! json.write(to: queue)

        let loaded = try! LanLibrary.load(queueFile: queue, mediaRoot: fixture.media)
        precondition(loaded.item(id: rejectedID) == nil, "\(label)：条目不得出现在片库")
        precondition(loaded.videoURL(rejectedID) == nil, "\(label)：视频不得列出")
        precondition(loaded.videoURL(normalID)?.path == fixture.normalVideo.path, "\(label)：正常视频照常列出")
        precondition(loaded.thumbnailURL(normalID) == nil, "\(label)：封面不得提供")
        precondition(loaded.subtitleURL(normalID) == nil, "\(label)：字幕不得提供")

        let token = "media-root-token"
        func leaks(_ body: Data) -> Bool {
            String(data: body, encoding: .utf8)?.contains(MediaRootFixture.secret) == true
        }
        let swapped = LanLibrary(
            items: [LanCatalogItem(id: rejectedID, title: "片库外", durationText: "0:05", hasThumbnail: true, hasChineseSubtitle: true)],
            videos: [rejectedID: video],
            thumbnails: [rejectedID: thumb],
            subtitles: [rejectedID: subtitle],
            mediaRoot: fixture.media
        )
        for kind in ["video", "thumb", "subtitle"] {
            let response = LanHTTP.handle(
                LanHTTPRequest(method: "GET", path: "/\(kind)/\(rejectedID.uuidString)", query: ["k": token], headers: [:], remoteHost: "127.0.0.1"),
                token: token,
                library: swapped
            )
            precondition(response.status == 404, "\(label)：读取时必须 404：\(kind) 实际 \(response.status)")
            precondition(response.file == nil && !leaks(response.body), "\(label)：读取时不得返回片库外内容：\(kind)")
        }

        let runtime = LanPlayerRuntime(queueFile: queue, mediaRoot: fixture.media, token: token)
        try! runtime.start(hosts: ["127.0.0.1"], port: 0)
        defer { runtime.stop() }
        let session = URLSession(configuration: .ephemeral)
        let base = "http://127.0.0.1:\(runtime.port)"
        for path in [
            "/video/\(rejectedID.uuidString)",
            "/thumb/\(rejectedID.uuidString)",
            "/subtitle/\(rejectedID.uuidString)",
            "/thumb/\(normalID.uuidString)",
            "/subtitle/\(normalID.uuidString)"
        ] {
            let result = data(session, url("\(base)\(path)?k=\(token)"))
            precondition(result.status == 404, "\(label)：HTTP 必须 404：\(path) 实际 \(result.status)")
            precondition(!leaks(result.body), "\(label)：HTTP 不得返回片库外内容：\(path)")
        }
        let normal = data(session, url("\(base)/video/\(normalID.uuidString)?k=\(token)"))
        precondition(normal.status == 200 && normal.body == Data("normal-video".utf8), "\(label)：正常视频照常播放")
    }

    /// 登记路径本身是指向片库外的符号链接。
    private static func checkSymlinkEntriesRejected() {
        let fixture = MediaRootFixture("lan-player-symlink")
        defer { fixture.remove() }
        let fm = FileManager.default
        var paths: [String] = []
        for name in ["movie.mp4", "movie.jpg", "movie.zh.srt"] {
            let link = fixture.media.appendingPathComponent("linked-\(name)")
            try! fm.createSymbolicLink(at: link, withDestinationURL: fixture.outside.appendingPathComponent(name))
            paths.append(link.path)
        }
        assertOutsideRejected(fixture, video: paths[0], thumb: paths[1], subtitle: paths[2], label: "直接链接")
    }

    /// 登记路径最后一段是普通文件，但上级目录是指向片库外的符号链接。
    private static func checkParentDirectorySymlinkRejected() {
        let fixture = MediaRootFixture("lan-player-parent-link")
        defer { fixture.remove() }
        let library = fixture.media.appendingPathComponent("library", isDirectory: true)
        try! FileManager.default.createSymbolicLink(at: library, withDestinationURL: fixture.outside)
        assertOutsideRejected(
            fixture,
            video: library.appendingPathComponent("movie.mp4").path,
            thumb: library.appendingPathComponent("movie.jpg").path,
            subtitle: library.appendingPathComponent("movie.zh.srt").path,
            label: "父目录链接"
        )
    }

    /// 没有任何链接：队列直接登记片库外的普通文件，或用 .. 从片库里绕出去。
    private static func checkOutsideMediaRootRejected() {
        let fixture = MediaRootFixture("lan-player-outside")
        defer { fixture.remove() }
        assertOutsideRejected(
            fixture,
            video: fixture.outside.appendingPathComponent("movie.mp4").path,
            thumb: fixture.outside.appendingPathComponent("movie.jpg").path,
            subtitle: fixture.outside.appendingPathComponent("movie.zh.srt").path,
            label: "片库外普通文件"
        )
        let dotdot = fixture.media.path + "/../outside/"
        assertOutsideRejected(
            fixture,
            video: dotdot + "movie.mp4",
            thumb: dotdot + "movie.jpg",
            subtitle: dotdot + "movie.zh.srt",
            label: "点点路径"
        )
    }

    private static func checkBindRestrictedToPrivate() {
        for host in ["0.0.0.0", "8.8.8.8", "169.254.10.10", "172.32.0.1", "1.2.3.4"] {
            let runtime = LanPlayerRuntime(
                queueFile: URL(fileURLWithPath: "/nonexistent/queue.json"),
                mediaRoot: URL(fileURLWithPath: "/nonexistent"),
                token: "t"
            )
            var rejected = false
            do {
                try runtime.start(hosts: [host], port: 0)
                runtime.stop()
            } catch {
                rejected = error.localizedDescription.contains("只能监听")
            }
            precondition(rejected, "非私网、非回环地址必须拒绝监听：\(host)")
        }
        for host in ["127.0.0.1", "10.0.0.1", "172.16.0.1", "172.31.255.1", "192.168.1.1"] {
            precondition(LanNet.isAllowedBindHost(host), "私网与回环地址允许监听：\(host)")
        }
        for host in ["0.0.0.0", "8.8.8.8", "169.254.1.1", "172.15.0.1", "255.255.255.255", "abc", ""] {
            precondition(!LanNet.isAllowedBindHost(host), "其余地址一律拒绝：\(host)")
        }
    }

    private static func checkMethodsAndAuthOrder() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lan-player-method-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let video = root.appendingPathComponent("v.mp4")
        try! Data("method-video".utf8).write(to: video)
        let queue = root.appendingPathComponent("queue.json")
        try! Data("""
        [{"id":"\(id.uuidString)","title":"片","duration":1,"state":"ready","localFilePath":"\(video.path)"}]
        """.utf8).write(to: queue)
        let token = "method-token"
        let runtime = LanPlayerRuntime(queueFile: queue, mediaRoot: root, token: token)
        try! runtime.start(hosts: ["127.0.0.1"], port: 0)
        defer { runtime.stop() }
        let session = URLSession(configuration: .ephemeral)
        let target = url("http://127.0.0.1:\(runtime.port)/video/\(id.uuidString)?k=\(token)")

        for method in ["DELETE", "POST", "PUT"] {
            var request = URLRequest(url: target)
            request.httpMethod = method
            let result = data(session, request)
            precondition(result.status == 405, "\(method) 必须 405，实际 \(result.status)")
            precondition(result.header("Allow") == "GET, HEAD", "405 要带 Allow 头")
            precondition(result.body != Data("method-video".utf8), "\(method) 不得返回文件内容")
        }
        var head = URLRequest(url: target)
        head.httpMethod = "HEAD"
        let headResult = data(session, head)
        precondition(headResult.status == 200 && headResult.body.isEmpty, "HEAD 只回头部")

        // 队列读不了时，没带访问码仍然 403，说明先鉴权再解析队列。
        try! Data("not json".utf8).write(to: queue)
        let unauth = data(session, url("http://127.0.0.1:\(runtime.port)/"))
        precondition(unauth.status == 403, "没带访问码时先回 403，不解析队列，实际 \(unauth.status)")
        let authed = data(session, url("http://127.0.0.1:\(runtime.port)/?k=\(token)"))
        precondition(authed.status == 500, "带访问码且队列损坏时才回 500")
    }

    private static func url(_ string: String) -> URL {
        URL(string: string)!
    }

    private static func data(_ session: URLSession, _ url: URL) -> HTTPResult {
        data(session, URLRequest(url: url))
    }

    private static func data(_ session: URLSession, _ request: URLRequest) -> HTTPResult {
        let box = ResultBox()
        let sema = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { body, response, error in
            box.error = error
            box.response = response as? HTTPURLResponse
            box.body = body ?? Data()
            sema.signal()
        }.resume()
        precondition(sema.wait(timeout: .now() + 5) == .success, "HTTP 请求超时")
        precondition(box.error == nil, "HTTP 请求失败：\(box.error!.localizedDescription)")
        var headers: [String: String] = [:]
        if let fields = box.response?.allHeaderFields {
            for (key, value) in fields {
                headers["\(key)"] = "\(value)"
            }
        }
        return HTTPResult(status: box.response?.statusCode ?? 0, headers: headers, body: box.body)
    }

    private struct HTTPResult {
        var status: Int
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? {
            let key = name.lowercased()
            return headers.first { $0.key.lowercased() == key }?.value
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var error: Error?
        var response: HTTPURLResponse?
        var body = Data()
    }
}
