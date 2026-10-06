import Foundation

final class DownloadEngine {
    struct Metadata {
        let title: String
        let author: String
        let duration: Double?
        let chapters: [VideoChapter]
    }

    struct Result {
        let fileURL: URL
        let thumbnailFileURL: URL?
        let subtitleFileURL: URL?
        let metadata: Metadata
    }

    enum Event {
        case metadata(Metadata)
        case progress(Double, String)
        case playbackSource(VideoPlaybackSource)
        case subtitleFile(URL)
    }

    enum EngineError: LocalizedError {
        case missingTool(String)
        case failed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .missingTool(let tool): return "未安装 \(tool)，请用 Homebrew 安装后重试。"
            case .failed(let message): return message
            case .cancelled: return "下载已取消。"
            }
        }
    }

    private let processLock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var resolverProcesses: [UUID: Process] = [:]
    private let metadataQueue = DispatchQueue(label: "ai.openmy.seesee.metadata", qos: .utility)
    private let subtitleScanQueue = DispatchQueue(label: "ai.openmy.seesee.subtitle-scan", qos: .utility)
    private let playbackQueue = DispatchQueue(
        label: "ai.openmy.seesee.progressive-playback",
        qos: .userInitiated,
        attributes: .concurrent
    )
    // Prefer a single progressive stream for immediate playback. YouTube's
    // 1080p representation is normally split into separate video and audio
    // files; AVFoundation can take a long time to index those through a remote
    // composition. The combined stream starts directly while the download
    // format continues fetching the full-quality offline copy in parallel.
    private static let progressiveFormat = "b[height<=720][ext=mp4][vcodec!=none][acodec!=none][protocol^=http]/b[height<=720][vcodec!=none][acodec!=none]/best"

    func start(
        itemID: UUID,
        sourceURL: URL,
        destination: URL,
        onEvent: @escaping (Event) -> Void,
        completion: @escaping (Swift.Result<DownloadEngine.Result, Error>) -> Void
    ) {
        // Resolve a directly playable source independently of the offline
        // download. The direct combined stream can start without waiting for
        // yt-dlp to finish downloading and merging the high-quality local copy.
        // 拿不到合流地址时不发事件，界面照旧等下完再播。
        playbackQueue.async { [weak self] in
            guard let self,
                  let source = try? self.resolvePlaybackSource(itemID: itemID, sourceURL: sourceURL) else { return }
            onEvent(.playbackSource(source))
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let ytDlp = try self.requiredTool(named: "yt-dlp")
                let ffmpeg = try self.requiredTool(named: "ffmpeg")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

                let process = Process()
                let output = Pipe()
                process.executableURL = ytDlp
                process.standardOutput = output
                process.standardError = output
                process.currentDirectoryURL = destination
                process.environment = self.processEnvironment()

                var arguments = [
                    "--ignore-config",
                    "--no-playlist",
                    "--continue",
                    "--part",
                    "--newline",
                    // 下面的 --print 会让 yt-dlp 进入安静模式，不加 --progress 就没有进度行，界面一直停在「准备下载…」。
                    "--progress",
                    "--no-color",
                    "--paths", destination.path,
                    "--output", "\(itemID.uuidString).%(ext)s",
                    "--format", "bv*[height<=1080][ext=mp4]+ba[ext=m4a]/b[height<=1080][ext=mp4]/b[height<=1080]/best",
                    "--merge-output-format", "mp4",
                    "--write-thumbnail",
                    "--convert-thumbnails", "jpg",
                    "--write-subs",
                    "--write-auto-subs",
                    // 中文优先：简/繁 + 英译中（*-en）；英文回退。
                    // 不用 zh.* / en.* 通配：会匹配 zh-Hans-de 等无关变体，请求过多易 429。
                    "--sub-langs", "zh-Hans,zh-Hant,zh-Hans-en,zh-Hant-en,en,en-orig,-live_chat",
                    // 某一轨字幕 429/失败时仍完成视频下载；字幕由 discoverSubtitle / 后续补拉处理。
                    "--ignore-errors",
                    "--sub-format", "vtt/best",
                    "--convert-subs", "srt",
                    "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                    "--progress-template", "download:WL_PROGRESS\t%(progress._percent_str)s\t%(progress._speed_str)s\t%(progress._eta_str)s",
                    "--print", "before_dl:WL_META\t%(title)j\t%(uploader)j\t%(duration)j\t%(chapters)j",
                    "--print", "after_move:WL_DONE\t%(filepath)j\t%(title)j\t%(uploader)j\t%(duration)j\t%(chapters)j"
                ]
                if let deno = self.findTool(named: "deno") {
                    arguments += ["--js-runtimes", "deno:\(deno.path)"]
                }
                arguments.append(sourceURL.absoluteString)
                process.arguments = arguments

                self.setProcess(process, for: itemID)
                try process.run()

                var pending = ""
                var recentLines: [String] = []
                var latestMetadata = Metadata(
                    title: sourceURL.host ?? "视频",
                    author: "",
                    duration: nil,
                    chapters: []
                )
                var finishedFile: URL?
                let subtitleScan = self.startSubtitleScan(itemID: itemID, destination: destination, onEvent: onEvent)
                defer { self.stopSubtitleScan(subtitleScan) }

                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending += String(decoding: data, as: UTF8.self)
                    let lines = pending.components(separatedBy: .newlines)
                    pending = lines.last ?? ""
                    for line in lines.dropLast() {
                        self.parse(
                            line: line,
                            metadata: &latestMetadata,
                            finishedFile: &finishedFile,
                            recentLines: &recentLines,
                            onEvent: onEvent
                        )
                    }
                }
                // 下载结束：先停掉字幕扫描，再报完成，晚到的扫描结果不会盖掉完成时的字幕。
                self.stopSubtitleScan(subtitleScan)
                if !pending.isEmpty {
                    self.parse(
                        line: pending,
                        metadata: &latestMetadata,
                        finishedFile: &finishedFile,
                        recentLines: &recentLines,
                        onEvent: onEvent
                    )
                }
                process.waitUntilExit()
                self.removeProcess(for: itemID)

                if process.terminationReason == .uncaughtSignal {
                    throw EngineError.cancelled
                }
                guard process.terminationStatus == 0 else {
                    let useful = recentLines.suffix(10).joined(separator: "\n")
                    throw EngineError.failed(useful.isEmpty ? "yt-dlp 退出，状态码 \(process.terminationStatus)。" : useful)
                }
                guard let fileURL = finishedFile ?? self.discoverFile(for: itemID, in: destination) else {
                    throw EngineError.failed("下载完成，但找不到对应的本地文件。")
                }
                completion(.success(Result(
                    fileURL: fileURL,
                    thumbnailFileURL: self.discoverThumbnail(for: itemID, in: destination),
                    subtitleFileURL: self.discoverSubtitle(for: itemID, in: destination),
                    metadata: latestMetadata
                )))
            } catch {
                self.removeProcess(for: itemID)
                completion(.failure(error))
            }
        }
    }

    func cancel(itemID: UUID) {
        processLock.lock()
        let process = processes[itemID]
        let resolver = resolverProcesses[itemID]
        processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
        // 预览解析也一起停：删除还在解析预览的条目时，不留后台进程。
        if resolver?.isRunning == true { resolver?.terminate() }
    }

    private func resolvePlaybackSource(itemID: UUID, sourceURL: URL) throws -> VideoPlaybackSource {
        let ytDlp = try requiredTool(named: "yt-dlp")
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = ytDlp
        process.standardOutput = output
        process.standardError = errors
        process.environment = processEnvironment()
        var arguments = [
            "--ignore-config",
            "--no-playlist",
            "--no-color",
            "--no-warnings",
            // The Android client still exposes YouTube's progressive format 18
            // on videos where the default client only offers separate tracks.
            // This applies only to the early-playback resolver; the offline
            // download keeps its normal high-quality format/client selection.
            "--extractor-args", "youtube:player_client=android",
            "--format", Self.progressiveFormat,
            "--get-url"
        ]
        if let deno = findTool(named: "deno") {
            arguments += ["--js-runtimes", "deno:\(deno.path)"]
        }
        arguments.append(sourceURL.absoluteString)
        process.arguments = arguments

        setResolverProcess(process, for: itemID)
        defer { removeResolverProcess(process, for: itemID) }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError.failed(message.isEmpty ? "无法准备在线预览。" : message)
        }

        let urls = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .compactMap { line -> URL? in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return nil }
                return URL(string: value)
            }
        guard let videoURL = urls.first else {
            throw EngineError.failed("视频网站没有给出可以直接播放的地址。")
        }
        return VideoPlaybackSource(videoURL: videoURL)
    }

    func fetchMetadata(
        sourceURL: URL,
        completion: @escaping (Swift.Result<Metadata, Error>) -> Void
    ) {
        metadataQueue.async { [weak self] in
            guard let self else { return }
            do {
                let ytDlp = try self.requiredTool(named: "yt-dlp")
                let process = Process()
                let output = Pipe()
                process.executableURL = ytDlp
                process.standardOutput = output
                process.standardError = output
                process.environment = self.processEnvironment()
                var arguments = [
                    "--ignore-config",
                    "--no-playlist",
                    "--skip-download",
                    "--no-color",
                    "--print", "WL_META\t%(title)j\t%(uploader)j\t%(duration)j\t%(chapters)j"
                ]
                if let deno = self.findTool(named: "deno") {
                    arguments += ["--js-runtimes", "deno:\(deno.path)"]
                }
                arguments.append(sourceURL.absoluteString)
                process.arguments = arguments

                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw EngineError.failed("无法刷新视频的章节信息。")
                }

                var metadata = Metadata(
                    title: sourceURL.host ?? "视频",
                    author: "",
                    duration: nil,
                    chapters: []
                )
                var finishedFile: URL?
                var recentLines: [String] = []
                for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
                    self.parse(
                        line: line,
                        metadata: &metadata,
                        finishedFile: &finishedFile,
                        recentLines: &recentLines,
                        onEvent: { _ in }
                    )
                }
                completion(.success(metadata))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func fetchThumbnail(
        itemID: UUID,
        sourceURL: URL,
        destination: URL,
        completion: @escaping (Swift.Result<URL?, Error>) -> Void
    ) {
        metadataQueue.async { [weak self] in
            guard let self else { return }
            do {
                let ytDlp = try self.requiredTool(named: "yt-dlp")
                let ffmpeg = try self.requiredTool(named: "ffmpeg")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

                let process = Process()
                let output = Pipe()
                process.executableURL = ytDlp
                process.standardOutput = output
                process.standardError = output
                process.environment = self.processEnvironment()
                var arguments = [
                    "--ignore-config",
                    "--no-playlist",
                    "--skip-download",
                    "--write-thumbnail",
                    "--convert-thumbnails", "jpg",
                    "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                    "--paths", destination.path,
                    "--output", "\(itemID.uuidString).%(ext)s"
                ]
                if let deno = self.findTool(named: "deno") {
                    arguments += ["--js-runtimes", "deno:\(deno.path)"]
                }
                arguments.append(sourceURL.absoluteString)
                process.arguments = arguments

                try process.run()
                _ = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw EngineError.failed("无法缓存视频封面图。")
                }
                completion(.success(self.discoverThumbnail(for: itemID, in: destination)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func fetchSubtitle(
        itemID: UUID,
        sourceURL: URL,
        destination: URL,
        completion: @escaping (Swift.Result<URL?, Error>) -> Void
    ) {
        metadataQueue.async { [weak self] in
            guard let self else { return }
            do {
                let ytDlp = try self.requiredTool(named: "yt-dlp")
                let ffmpeg = try self.requiredTool(named: "ffmpeg")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

                let process = Process()
                let output = Pipe()
                process.executableURL = ytDlp
                process.standardOutput = output
                process.standardError = output
                process.environment = self.processEnvironment()
                var arguments = [
                    "--ignore-config",
                    "--no-playlist",
                    "--skip-download",
                    "--no-color",
                    "--write-subs",
                    "--write-auto-subs",
                    // 中文优先：简/繁 + 英译中（*-en）；英文回退。
                    // 不用 zh.* / en.* 通配：会匹配 zh-Hans-de 等无关变体，请求过多易 429。
                    "--sub-langs", "zh-Hans,zh-Hant,zh-Hans-en,zh-Hant-en,en,en-orig,-live_chat",
                    "--ignore-errors",
                    "--sub-format", "vtt/best",
                    "--convert-subs", "srt",
                    "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                    "--paths", destination.path,
                    "--output", "\(itemID.uuidString).%(ext)s"
                ]
                if let deno = self.findTool(named: "deno") {
                    arguments += ["--js-runtimes", "deno:\(deno.path)"]
                }
                arguments.append(sourceURL.absoluteString)
                process.arguments = arguments

                try process.run()
                _ = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw EngineError.failed("无法缓存这个视频的字幕。")
                }
                completion(.success(self.discoverSubtitle(for: itemID, in: destination)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func fetchFlatPlaylist(
        sourceURL: URL,
        limit: Int,
        completion: @escaping (Swift.Result<[PlaylistListing.Entry], Error>) -> Void
    ) {
        metadataQueue.async { [weak self] in
            guard let self else { return }
            do {
                let ytDlp = try self.requiredTool(named: "yt-dlp")
                let process = Process()
                let output = Pipe()
                let errorOutput = Pipe()
                process.executableURL = ytDlp
                process.standardOutput = output
                process.standardError = errorOutput
                process.environment = self.processEnvironment()
                var arguments = [
                    "--ignore-config",
                    "--flat-playlist",
                    "--skip-download",
                    "--no-color",
                    "--playlist-end", "\(limit)",
                    "--print", "%(id)s|%(title)s|%(webpage_url)s"
                ]
                if ChannelLink.usesPlaylistOrder(sourceURL) {
                    arguments.append("--playlist-reverse")
                }
                if let deno = self.findTool(named: "deno") {
                    arguments += ["--js-runtimes", "deno:\(deno.path)"]
                }
                arguments.append(sourceURL.absoluteString)
                process.arguments = arguments

                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let message = String(decoding: errorData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw EngineError.failed(
                        message.isEmpty ? "无法读取这个频道的视频列表。" : message
                    )
                }
                let text = String(decoding: data, as: UTF8.self)
                completion(.success(PlaylistListing.parse(text, sourceURL: sourceURL)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func parse(
        line: String,
        metadata: inout Metadata,
        finishedFile: inout URL?,
        recentLines: inout [String],
        onEvent: (Event) -> Void
    ) {
        if line.hasPrefix("WL_PROGRESS\t") {
            let fields = line.components(separatedBy: "\t")
            let rawPercent = fields.count > 1 ? fields[1] : ""
            let numeric = rawPercent.replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            let fraction = min(max((Double(numeric) ?? 0) / 100, 0), 1)
            let speed = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
            let eta = fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespaces) : ""
            let label = [rawPercent.trimmingCharacters(in: .whitespaces), speed, eta.isEmpty ? "" : "剩余 \(eta)"]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            onEvent(.progress(fraction, label))
            return
        }

        if line.hasPrefix("WL_META\t") || line.hasPrefix("WL_DONE\t") {
            let fields = line.components(separatedBy: "\t")
            let offset = line.hasPrefix("WL_DONE\t") ? 2 : 1
            if line.hasPrefix("WL_DONE\t"), fields.count > 1,
               let path: String = decodeJSON(fields[1]), !path.isEmpty {
                finishedFile = URL(fileURLWithPath: path)
            }
            let title: String = fields.count > offset ? decodeJSON(fields[offset]) ?? metadata.title : metadata.title
            let author: String = fields.count > offset + 1 ? decodeJSON(fields[offset + 1]) ?? metadata.author : metadata.author
            let duration: Double? = fields.count > offset + 2 ? decodeJSON(fields[offset + 2]) : metadata.duration
            let chapters = fields.count > offset + 3
                ? ChapterMetadata.decode(json: fields[offset + 3]) ?? metadata.chapters
                : metadata.chapters
            metadata = Metadata(title: title, author: author, duration: duration, chapters: chapters)
            onEvent(.metadata(metadata))
            return
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            recentLines.append(trimmed)
            if recentLines.count > 30 { recentLines.removeFirst() }
        }
    }

    private func decodeJSON<T>(_ value: String) -> T? {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if decoded is NSNull { return nil }
        return decoded as? T
    }

    private func requiredTool(named name: String) throws -> URL {
        guard let tool = findTool(named: name) else { throw EngineError.missingTool(name) }
        return tool
    }

    private func findTool(named name: String) -> URL? {
        var candidates: [String] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Tools/\(name)").path)
        }
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let bundledTools = Bundle.main.resourceURL?.appendingPathComponent("Tools").path
        environment["PATH"] = [
            bundledTools,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        .compactMap { $0 }
        .joined(separator: ":")
        return environment
    }

    private func discoverFile(for itemID: UUID, in folder: URL) -> URL? {
        let prefix = itemID.uuidString + "."
        let supported = Set(["mp4", "webm", "mkv", "mov", "m4v"])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && supported.contains($0.pathExtension.lowercased()) }
            .max { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
            }
    }

    private func discoverThumbnail(for itemID: UUID, in folder: URL) -> URL? {
        let prefix = itemID.uuidString + "."
        let supported = Set(["jpg", "jpeg", "png", "webp"])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter {
            $0.lastPathComponent.hasPrefix(prefix) && supported.contains($0.pathExtension.lowercased())
        }
        .max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }

    /// 下载进行中每秒扫一次片库目录：字幕先于视频数据落盘，在线预览阶段就能挂上。
    /// 不靠 yt-dlp 的输出触发：带 --print 时它不打印进度，下载中几乎没有输出。
    /// seesee 一次下好几种语言，最优的一轨会随文件陆续落盘而变，所以变了就再报一次。
    private func startSubtitleScan(
        itemID: UUID,
        destination: URL,
        onEvent: @escaping (Event) -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: subtitleScanQueue)
        var announced: URL?
        timer.schedule(deadline: .now() + 0.5, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self,
                  let subtitleURL = self.discoverSubtitle(for: itemID, in: destination),
                  subtitleURL.pathExtension.lowercased() == "srt",
                  subtitleURL != announced else { return }
            announced = subtitleURL
            onEvent(.subtitleFile(subtitleURL))
        }
        timer.resume()
        return timer
    }

    /// 在扫描队列上停：正在进行的那次扫描先做完，之后不会再报。
    private func stopSubtitleScan(_ timer: DispatchSourceTimer) {
        subtitleScanQueue.sync {
            if !timer.isCancelled { timer.cancel() }
        }
    }

    /// 纯本地扫描媒体目录字幕，不起进程、不联网。经 metadataQueue 回调，避免主线程 IO。
    func discoverLocalSubtitle(
        itemID: UUID,
        in folder: URL,
        completion: @escaping (URL?) -> Void
    ) {
        metadataQueue.async { [weak self] in
            guard let self else { return }
            completion(self.discoverSubtitle(for: itemID, in: folder))
        }
    }

    private func discoverSubtitle(for itemID: UUID, in folder: URL) -> URL? {
        let prefix = itemID.uuidString + "."
        let supported = Set(["srt", "vtt"])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter {
                $0.lastPathComponent.hasPrefix(prefix) && supported.contains($0.pathExtension.lowercased())
            }
            .sorted { lhs, rhs in
                let leftRank = SubtitleTrackRank.value(for: lhs)
                let rightRank = SubtitleTrackRank.value(for: rhs)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.lastPathComponent.count < rhs.lastPathComponent.count
            }
            .first
    }

    private func setProcess(_ process: Process, for itemID: UUID) {
        processLock.lock()
        processes[itemID] = process
        processLock.unlock()
    }

    private func removeProcess(for itemID: UUID) {
        processLock.lock()
        processes.removeValue(forKey: itemID)
        processLock.unlock()
    }

    private func setResolverProcess(_ process: Process, for itemID: UUID) {
        processLock.lock()
        resolverProcesses[itemID] = process
        processLock.unlock()
    }

    /// 重试时新旧两次解析可能重叠，只移走自己登记的那一个。
    private func removeResolverProcess(_ process: Process, for itemID: UUID) {
        processLock.lock()
        if resolverProcesses[itemID] === process {
            resolverProcesses.removeValue(forKey: itemID)
        }
        processLock.unlock()
    }
}
