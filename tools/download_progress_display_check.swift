import Foundation

/// 锁住下载中的显示规则：队列行、缩略图圆环、右侧等待画面和预览标记显示什么。
/// 进度文字按 DownloadEngine 的拼法合成（「百分比 · 速度 · 剩余 时间」），读数取自 2026-10-06 用应用同一组参数、
/// 加 --progress 后的真实 yt-dlp 输出：先两个字幕文件，再视频，再音频。
@main
struct DownloadProgressDisplayCheck {
    /// 真实日志的 60 行进度：第 1 到 6 行是字幕，第 7 到 47 行是视频，第 48 到 60 行是音频。
    static let realRun = """
    0.0%|Unknown B/s|Unknown;0.0%|Unknown B/s|Unknown;100.0%|4.78KiB/s|NA;0.0%|Unknown B/s|Unknown;0.0%|Unknown B/s|Unknown;\
    100.0%|2.48KiB/s|NA;0.0%|220.61KiB/s|01:46;0.0%|620.73KiB/s|00:37;0.0%|1.38MiB/s|00:16;0.1%|2.88MiB/s|00:07;\
    0.1%|1.95MiB/s|00:11;0.3%|2.44MiB/s|00:09;0.5%|3.25MiB/s|00:06;1.1%|4.42MiB/s|00:05;2.2%|7.54MiB/s|00:02;\
    4.4%|8.76MiB/s|00:02;8.7%|7.60MiB/s|00:02;17.5%|6.55MiB/s|00:02;35.0%|6.16MiB/s|00:02;42.3%|6.11MiB/s|00:02;\
    42.3%|Unknown B/s|Unknown;42.3%|Unknown B/s|Unknown;42.4%|Unknown B/s|Unknown;42.4%|Unknown B/s|Unknown;\
    42.5%|Unknown B/s|Unknown;42.6%|11.32MiB/s|00:01;42.9%|6.39MiB/s|00:02;43.4%|8.57MiB/s|00:01;44.5%|7.05MiB/s|00:01;\
    46.7%|8.40MiB/s|00:01;51.1%|8.26MiB/s|00:01;59.8%|6.89MiB/s|00:01;77.3%|6.21MiB/s|00:00;85.4%|6.15MiB/s|00:00;\
    85.4%|613.92KiB/s|00:05;85.4%|1.53MiB/s|00:02;85.4%|3.32MiB/s|00:01;85.5%|6.50MiB/s|00:00;85.5%|8.95MiB/s|00:00;\
    85.7%|7.43MiB/s|00:00;85.9%|7.70MiB/s|00:00;86.5%|8.43MiB/s|00:00;87.6%|9.69MiB/s|00:00;89.8%|11.62MiB/s|00:00;\
    94.1%|8.35MiB/s|00:00;100.0%|7.17MiB/s|00:00;100.0%|5.01MiB/s|NA;0.0%|666.19KiB/s|00:03;0.1%|1.66MiB/s|00:01;\
    0.3%|3.60MiB/s|00:00;0.6%|7.27MiB/s|00:00;1.3%|14.08MiB/s|00:00;2.7%|23.62MiB/s|00:00;5.4%|20.12MiB/s|00:00;\
    10.7%|17.83MiB/s|00:00;21.5%|14.47MiB/s|00:00;43.1%|9.80MiB/s|00:00;86.2%|8.11MiB/s|00:00;100.0%|7.82MiB/s|00:00;\
    100.0%|4.26MiB/s|NA
    """

    static func main() {
        let readings = realRun.split(separator: ";").map { line -> (Double, String) in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return engineReading(percent: parts[0], speed: parts[1], eta: parts[2])
        }
        precondition(readings.count == 60, "真实日志应有 60 行，实际 \(readings.count)")

        // 1. 按真实顺序回放：字幕期间说「准备下载」，视频期间圆环只进不退，音频期间一直「即将完成」。
        let full = simulate(readings)
        for index in 0..<9 {
            expect(full[index].phase == .preparing && full[index].percent == nil, "第 \(index + 1) 行（字幕或视频开头的 0.0%）只说准备下载", full[index])
            expect(full[index].rowText == "准备下载" && full[index].paneDetail == nil, "第 \(index + 1) 行不显示 0% 或速度", full[index])
        }
        var lastRing = 0.0
        for index in 9..<45 {
            let shown = full[index]
            expect(shown.phase == .downloading, "第 \(index + 1) 行是视频本体下载中，不能说即将完成", shown)
            expect((shown.ringFraction ?? 0) >= lastRing, "第 \(index + 1) 行圆环回退了", shown)
            lastRing = shown.ringFraction ?? 0
        }
        expect(full[18].rowText == "35%" && full[18].paneDetail == "6.5 MB/s", "35% 这一行：剩余 2 秒不显示", full[18])
        expect(full[21].rowText == "42%" && full[21].paneDetail == nil, "中途拿不到速度时只留百分比", full[21])
        expect(full[34].paneDetail == "629 KB/s · 剩余 5 秒", "85% 这一行：KiB/s 换成 KB/s，带剩余时间", full[34])
        for index in 45..<60 {
            expect(full[index].phase == .finishing && full[index].rowText == "即将完成" && full[index].paneTitle == "即将完成", "第 \(index + 1) 行（视频下完、音频从 0% 开始）一直是即将完成", full[index])
            expect(full[index].ringFraction == 1 && full[index].paneDetail == nil, "第 \(index + 1) 行满格，不显示音频的速度", full[index])
        }

        // 2. 界面合并密集事件时会漏行：去掉视频结尾两行和音频第一行，结论不变。
        var coalesced = readings
        coalesced.removeSubrange(45...47)
        let merged = simulate(coalesced)
        expect(merged[44].phase == .downloading, "合并后视频最后一行 94% 仍在下载中", merged[44])
        for shown in merged[45...] {
            expect(shown.phase == .finishing, "合并后音频阶段仍是即将完成", shown)
        }

        // 3. 慢网络下字幕也有中间读数和较长剩余时间，被当成视频本体；真正的视频一开始（剩余 30 秒以上）就改正过来。
        let slowSubtitle = [
            engineReading(percent: "40.0%", speed: "120.00KiB/s", eta: "00:04"),
            engineReading(percent: "100.0%", speed: "118.00KiB/s", eta: "NA"),
            engineReading(percent: "0.0%", speed: "300.00KiB/s", eta: "05:10"),
            engineReading(percent: "0.4%", speed: "2.00MiB/s", eta: "02:30"),
            engineReading(percent: "12.0%", speed: "2.10MiB/s", eta: "02:10"),
        ]
        let corrected = simulate(slowSubtitle)
        expect(corrected[2].phase == .downloading && corrected[2].rowText == "0%", "新文件预计比刚才的还久：它才是视频本体，不说即将完成", corrected[2])
        expect(corrected[4].phase == .downloading && corrected[4].rowText == "12%", "真正的视频开始后显示它自己的进度", corrected[4])

        // 3b. 长片：视频要下几十分钟，音频也要 45 秒。音频开始后一直是即将完成，不回到 0%，也不回到「准备下载」。
        let longFilm = simulate([
            engineReading(percent: "0.0%", speed: "500.00KiB/s", eta: "01:30:00"),
            engineReading(percent: "0.2%", speed: "5.00MiB/s", eta: "40:12"),
            engineReading(percent: "55.0%", speed: "5.10MiB/s", eta: "18:00"),
            engineReading(percent: "99.6%", speed: "5.00MiB/s", eta: "00:05"),
            engineReading(percent: "0.0%", speed: "1.20MiB/s", eta: "00:45"),
            engineReading(percent: "0.3%", speed: "1.20MiB/s", eta: "00:44"),
            engineReading(percent: "60.0%", speed: "1.30MiB/s", eta: "00:18"),
        ])
        expect(longFilm[2].rowText == "55%" && longFilm[2].remainingText == "剩余 18 分钟", "长片下载中", longFilm[2])
        for shown in longFilm[4...] {
            expect(shown.phase == .finishing && shown.rowText == "即将完成", "长片的音频阶段一直是即将完成", shown)
        }

        // 4. 小文件（短片、快网络）没有出现过 2 秒以上的剩余时间：换文件时不当成收尾，按新文件重新走。
        let tiny = simulate([
            engineReading(percent: "50.0%", speed: "30.00MiB/s", eta: "00:00"),
            engineReading(percent: "100.0%", speed: "31.00MiB/s", eta: "00:00"),
            engineReading(percent: "30.0%", speed: "20.00MiB/s", eta: "00:00"),
        ])
        expect(tiny[2].phase == .downloading && tiny[2].rowText == "30%", "没把握是视频本体时不卡在即将完成", tiny[2])

        // 5. 准备阶段的状态词，以及能单独判断的读数。
        expect(model(.downloading, 0, "准备下载…").rowText == "准备下载", "准备阶段状态词", model(.downloading, 0, "准备下载…"))
        expect(model(.downloading, 0.4, "继续下载…").paneTitle == "继续下载", "重试后的准备阶段", model(.downloading, 0.4, "继续下载…"))
        expect(model(.downloading, 0, "下载中…").phase == .preparing, "引擎给空读数时的兜底文字", model(.downloading, 0, "下载中…"))
        let typical = model(.downloading, 0.37, "37.0% · 6.32MiB/s · 剩余 00:42")
        expect(typical.phase == .downloading && typical.percent == 37 && typical.rowText == "37%", "0.37 显示 37%，不能因浮点误差显示 36%", typical)
        expect(typical.paneTitle == "正在存到本地" && typical.paneDetail == "6.6 MB/s · 剩余 45 秒", "速度换成十进制单位，剩余时间按 5 秒取整", typical)
        expect(typical.previewBadge == nil, "没在播预览时不出标记", typical)
        expect(model(.downloading, 0.01, "1.0% · 408.01KiB/s · 剩余 00:57").paneDetail == "418 KB/s · 剩余 1 分钟", "KiB/s 换成 KB/s，57 秒按 1 分钟", model(.downloading, 0.01, "1.0% · 408.01KiB/s · 剩余 00:57"))
        expect(model(.downloading, 0.2, "20.0% · 2.00MiB/s · 剩余 02:05").remainingText == "剩余 3 分钟", "超过 1 分钟向上取整", model(.downloading, 0.2, "20.0% · 2.00MiB/s · 剩余 02:05"))
        expect(model(.downloading, 0.1, "10.0% · 1.00MiB/s · 剩余 01:02:03").remainingText == "剩余 1 小时 3 分", "超过 1 小时", model(.downloading, 0.1, "10.0% · 1.00MiB/s · 剩余 01:02:03"))
        expect(model(.downloading, 0.5, "50.0% · 3.00MiB/s · 剩余 --:--").remainingText == nil, "--:-- 不显示", model(.downloading, 0.5, "50.0% · 3.00MiB/s · 剩余 --:--"))

        // 6. 预览可播：队列行和播放器都有标记，同时给出下载进度；完整画质就绪后标记消失、不说话。
        let previewRun = simulate(readings, preview: true)
        expect(previewRun[0].previewBadge == "预览" && previewRun[0].rowText == "预览", "预览已能播、还没认出视频进度", previewRun[0])
        expect(previewRun[18].previewBadge == "预览 35%" && previewRun[18].rowText == "预览 · 35%", "预览中显示下载进度", previewRun[18])
        expect(previewRun[50].previewBadge == "预览 · 即将完成" && previewRun[50].rowText == "预览 · 即将完成", "预览中视频下完", previewRun[50])
        let retryTrack = DownloadProgressDisplay.Track(stage: .main, fraction: 0.4, longestEstimate: 42)
        let previewRetry = model(.queued, 0.4, "第 1/3 次重试，2 秒后", preview: true, track: retryTrack)
        expect(previewRetry.rowText == "第 1/3 次重试，2 秒后" && previewRetry.previewBadge == "预览 40%", "重试倒计时里预览继续播，标记停在上次进度", previewRetry)
        let ready = model(.ready, 1, "已下载", preview: true, track: retryTrack)
        expect(ready.phase == .ready && ready.rowText.isEmpty && ready.previewBadge == nil && !ready.showsRing, "就绪后不说话", ready)
        expect(DownloadProgressDisplay.advance(retryTrack, state: .ready, progress: 1, progressLabel: "已下载", isPreviewPlayable: false) == nil, "就绪后记录清掉", ready)
        expect(DownloadProgressDisplay.advance(retryTrack, state: .queued, progress: 0.4, progressLabel: "第 1/3 次重试，2 秒后", isPreviewPlayable: false) == nil, "没在播预览的排队清掉记录，重试重新算", ready)

        // 7. 排队、失败沿用原来的文字，不画圆环，动画停下。
        for label in ["排队中", "等待下载槽位", "等待网络连接", "低电量模式已暂停", "第 2/3 次重试，5 秒后", "等待恢复"] {
            let queued = model(.queued, 0, label)
            expect(queued.phase == .queued && queued.rowText == label && !queued.showsRing && queued.previewBadge == nil, "排队文字原样显示：\(label)", queued)
        }
        let failed = model(.failed, 0.4, "重试 3 次后失败")
        expect(failed.phase == .failed && failed.rowText == "重试 3 次后失败" && !failed.showsRing, "失败沿用原样式，圆环停下", failed)

        // 8. 任何读数都不能把 yt-dlp 的占位词或空位漏到界面上。
        let raw = [
            "准备下载…", "继续下载…", "下载中…", "N/A%", "N/A% · Unknown B/s · 剩余 Unknown",
            "0.0% · Unknown B/s · 剩余 Unknown", "12.5% · NaN B/s · 剩余 --:--", "100.0% · 5.04MiB/s · 剩余 NA",
            "37.0% · 6.32MiB/s", "37.0% · 剩余 00:42", "37.0%", "",
        ]
        var everything = full + merged + previewRun
        for label in raw {
            for preview in [false, true] {
                everything.append(model(.downloading, 0.37, label, preview: preview))
            }
        }
        for shown in everything {
            for text in [shown.rowText, shown.paneTitle, shown.paneDetail ?? "", shown.previewBadge ?? ""] {
                for junk in ["Unknown", "NA", "N/A", "NaN", "--", "%%", "· ·", "MiB", "KiB"] {
                    expect(!text.contains(junk), "显示出了「\(junk)」：\(text)", shown)
                }
                expect(!text.hasPrefix("·") && !text.hasSuffix("·") && !text.hasSuffix(" "), "留下了空位：\(text)", shown)
            }
        }

        print("download_progress_display=passed")
    }

    /// 按 DownloadEngine.parse 的拼法合成一条读数：进度是百分比除以 100，文字是「百分比 · 速度 · 剩余 时间」。
    static func engineReading(percent: String, speed: String, eta: String) -> (Double, String) {
        let fraction = min(max((Double(percent.replacingOccurrences(of: "%", with: "")) ?? 0) / 100, 0), 1)
        let label = [percent, speed, eta.isEmpty ? "" : "剩余 \(eta)"].filter { !$0.isEmpty }.joined(separator: " · ")
        return (fraction, label)
    }

    /// 像界面一样一条条推进记录，返回每一条读数下显示的内容。
    static func simulate(_ readings: [(Double, String)], preview: Bool = false) -> [DownloadProgressDisplay.Model] {
        var track: DownloadProgressDisplay.Track?
        return readings.map { progress, label in
            track = DownloadProgressDisplay.advance(track, state: .downloading, progress: progress, progressLabel: label, isPreviewPlayable: preview)
            return model(.downloading, progress, label, preview: preview, track: track)
        }
    }

    static func model(
        _ state: DownloadState,
        _ progress: Double,
        _ label: String,
        preview: Bool = false,
        track: DownloadProgressDisplay.Track? = nil
    ) -> DownloadProgressDisplay.Model {
        DownloadProgressDisplay.model(
            state: state,
            progress: progress,
            progressLabel: label,
            isPreviewPlayable: preview,
            track: track
        )
    }

    static func expect(_ condition: Bool, _ message: String, _ model: DownloadProgressDisplay.Model) {
        guard condition else {
            fatalError("download_progress_display: \(message)\n实际：\(model)")
        }
    }
}
