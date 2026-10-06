import Foundation

/// 下载中的圆环靠百分比。yt-dlp 只要参数里有 `--print` 就进入安静模式、不输出进度
/// （`--print` 的说明是 Implies --quiet，`--progress` 是 Show progress bar, even if in quiet mode），
/// 引擎不加 `--progress`，界面从头到尾停在「准备下载…」。
/// 这里把假的 yt-dlp 放进引擎找工具的第一个位置（可执行文件旁的 Tools 目录），按这条规则走一遍真实的
/// `DownloadEngine.start`：引擎必须传 `--progress`，按 `--progress-template` 输出的进度行必须解析成进度事件。
@main
struct DownloadEngineProgressCheck {
    /// 2026-10-06 真实 yt-dlp 日志里的读数，保留 yt-dlp 自己的左侧空格。
    static let samples: [(percent: String, speed: String, eta: String, fraction: Double, label: String)] = [
        ("  0.0%", "  408.01KiB/s", "00:57", 0.0, "0.0% · 408.01KiB/s · 剩余 00:57"),
        (" 37.0%", "   6.32MiB/s", "00:42", 0.37, "37.0% · 6.32MiB/s · 剩余 00:42"),
        (" 42.5%", " Unknown B/s", "Unknown", 0.425, "42.5% · Unknown B/s · 剩余 Unknown"),
        ("100.0%", "   7.23MiB/s", "00:00", 1.0, "100.0% · 7.23MiB/s · 剩余 00:00"),
    ]

    static func main() {
        let fileManager = FileManager.default
        guard let base = Bundle.main.resourceURL else {
            fatalError("download_engine_progress: 找不到可执行文件所在目录")
        }
        let tools = base.appendingPathComponent("Tools", isDirectory: true)
        let work = base.appendingPathComponent("download-engine-progress-work", isDirectory: true)
        cleanUp = {
            try? fileManager.removeItem(at: tools)
            try? fileManager.removeItem(at: work)
        }
        cleanUp()
        defer { cleanUp() }
        do {
            try fileManager.createDirectory(at: tools, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            let argsFile = work.appendingPathComponent("args.txt")
            try install(fakeYtDlp(argsFile: argsFile.path), at: tools.appendingPathComponent("yt-dlp"))
            try install("#!/bin/sh\nexit 0\n", at: tools.appendingPathComponent("ffmpeg"))

            var events: [DownloadEngine.Event] = []
            var outcome: Result<DownloadEngine.Result, Error>?
            let lock = NSLock()
            let finished = DispatchSemaphore(value: 0)
            // 引擎在后台队列里只弱引用自己，检查期间要一直拿着它。
            let engine = DownloadEngine()
            engine.start(
                itemID: UUID(),
                sourceURL: URL(string: "https://www.youtube.com/watch?v=SkVqJ1SGeL0")!,
                destination: work.appendingPathComponent("media", isDirectory: true),
                onEvent: { event in
                    lock.lock(); events.append(event); lock.unlock()
                },
                completion: { result in
                    outcome = result
                    finished.signal()
                }
            )
            guard finished.wait(timeout: .now() + 30) == .success else {
                fail("30 秒内引擎没有结束")
            }
            withExtendedLifetime(engine) {}

            let argv = (try String(contentsOf: argsFile, encoding: .utf8)).components(separatedBy: "\n")
            expect(argv.contains("--print"), "假 yt-dlp 没有收到 --print，检查前提变了")
            expect(
                argv.contains("--progress"),
                "引擎参数里有 --print 却没有 --progress，yt-dlp 会进入安静模式，不输出进度，界面一直停在「准备下载…」"
            )

            lock.lock()
            let progress = events.compactMap { event -> (Double, String)? in
                if case .progress(let fraction, let label) = event { return (fraction, label) }
                return nil
            }
            lock.unlock()
            expect(progress.count == samples.count, "收到 \(progress.count) 条进度事件，应为 \(samples.count) 条")
            for (index, sample) in samples.enumerated() {
                let (fraction, label) = progress[index]
                expect(abs(fraction - sample.fraction) < 0.0001, "第 \(index + 1) 行进度 \(fraction)，应为 \(sample.fraction)")
                expect(label == sample.label, "第 \(index + 1) 行文字「\(label)」，应为「\(sample.label)」")
            }

            guard case .success(let downloaded) = outcome else {
                fail("引擎没有成功结束：\(String(describing: outcome))")
            }
            expect(fileManager.fileExists(atPath: downloaded.fileURL.path), "引擎报告的文件不存在")
        } catch {
            fail("准备假工具失败 \(error)")
        }
        print("download_engine_progress=passed")
    }

    /// 失败时也要删掉假工具，不留给同一目录里后面运行的检查。
    static var cleanUp: () -> Void = {}

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) -> Never {
        cleanUp()
        fatalError("download_engine_progress: \(message)")
    }

    static func install(_ script: String, at url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// 假 yt-dlp：记下收到的参数；有 --print 又没有 --progress 时和真实 yt-dlp 一样安静；
    /// 否则按引擎传来的 --progress-template 逐行填入真实读数，最后按 --paths、--output 生成文件并打印 WL_DONE。
    static func fakeYtDlp(argsFile: String) -> String {
        let rows = samples.map { "\($0.percent)|\($0.speed)|\($0.eta)" }.joined(separator: "\n")
        return """
        #!/bin/bash
        args_file='\(argsFile)'
        : > "$args_file"
        has_print=0; has_progress=0; template=""; paths="."; output=""
        while [ $# -gt 0 ]; do
          printf '%s\\n' "$1" >> "$args_file"
          case "$1" in
            --print) has_print=1 ;;
            --progress) has_progress=1 ;;
            --progress-template) template="$2" ;;
            --paths) paths="$2" ;;
            --output) output="$2" ;;
          esac
          shift
        done
        printf 'WL_META\\t"Fake"\\t"Fake"\\t60\\tnull\\n'
        if [ "$has_print" = 1 ] && [ "$has_progress" = 0 ]; then
          :
        else
          tmpl="${template#download:}"
          while IFS='|' read -r pct speed eta; do
            line="${tmpl//'%(progress._percent_str)s'/$pct}"
            line="${line//'%(progress._speed_str)s'/$speed}"
            line="${line//'%(progress._eta_str)s'/$eta}"
            printf '%s\\n' "$line"
          done <<'SAMPLES'
        \(rows)
        SAMPLES
        fi
        file="$paths/${output//'%(ext)s'/mp4}"
        printf 'fake' > "$file"
        printf 'WL_DONE\\t"%s"\\t"Fake"\\t"Fake"\\t60\\tnull\\n' "$file"
        exit 0

        """
    }
}
