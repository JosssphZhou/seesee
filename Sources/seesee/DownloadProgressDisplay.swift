import Foundation

/// 下载中的显示层：把引擎写进 `progress`、`progressLabel` 的原始读数，换成队列行、缩略图圆环、
/// 右侧等待画面和预览标记要显示的数字和状态词。只解析文字，不改下载流程。
///
/// `progressLabel` 由 DownloadEngine 拼成「百分比 · 速度 · 剩余 时间」，每段都可能缺。
/// yt-dlp 拿不到读数时写 `Unknown B/s`、`Unknown`、`NA`，这些一律不显示，也不留空位。
enum DownloadProgressDisplay {
    enum Phase: Equatable {
        /// 排队、等网络、重试倒计时、低电量暂停：沿用原来的文字，不画圆环。
        case queued
        /// 已经开始，还没认出视频本体的进度：圆环转一段短弧。
        case preparing
        /// 视频本体下载中：圆环走进度。
        case downloading
        /// 视频本体下完，还在下音频或合并：圆环满格，慢慢明暗。
        case finishing
        /// 正常态，不说话。
        case ready
        /// 沿用原来的失败样式，动画停下。
        case failed
    }

    struct Model: Equatable {
        var phase: Phase
        /// 圆环进度 0...1。转短弧的准备阶段、就绪和失败时为 nil。
        var ringFraction: Double? = nil
        /// 圆环中间的百分比数字；没有百分比时为 nil。
        var percent: Int? = nil
        var speedText: String? = nil
        var remainingText: String? = nil
        /// 队列行状态文字；空字符串表示正常态，行里改显示作者名。
        var rowText: String
        /// 右侧等待画面的标题，只在画圆环的阶段使用。
        var paneTitle: String
        /// 右侧标题下面一行：速度 · 剩余时间；两样都没有时为 nil。
        var paneDetail: String? = nil
        /// 播放器上的预览标记；不在播预览时为 nil。
        var previewBadge: String? = nil

        /// 缩略图和右侧画圆环的阶段。
        var showsRing: Bool {
            phase == .preparing || phase == .downloading || phase == .finishing
        }
    }

    /// 一次下载里几个文件的进度怎么接成一个圆环。yt-dlp 依次下载字幕、视频、音频，
    /// 每个文件的进度都从 0% 走到 100%；圆环只跟视频本体（主文件）走，前后的小文件不算。
    /// 界面可能合并密集的进度事件，所以只认「掉落超过一半」是换了文件，不要求看到过 100%。
    struct Track: Equatable {
        enum Stage: Equatable {
            /// 还没认出主文件：字幕从 0% 直接跳到 100%，视频开头几行是 0.0%。
            case waiting
            /// 主文件下载中，进度只进不退。
            case main
            /// 主文件下完，在下音频或合并。
            case tail
        }

        var stage: Stage = .waiting
        var fraction: Double = 0
        /// 主文件期间见过的最长剩余时间（秒）。用它判断换文件后新文件是视频本体还是音频：
        /// 新文件预计比主文件还久，刚才的主文件就是字幕这类小文件；不比它久，就是视频下完在下音频。
        var longestEstimate = 0

        fileprivate static func started(_ value: Double, remaining: Int?) -> Track {
            guard value > 0, value < 0.999 else { return Track() }
            return Track(stage: .main, fraction: value, longestEstimate: remaining ?? 0)
        }
    }

    static let savingTitle = "正在存到本地"
    static let finishingWord = "即将完成"
    static let previewWord = "预览"
    private static let preparingWord = "准备下载"

    /// 按新读数推进一次下载的记录。同一读数重复推进，结果不变。
    /// 不在下载中（排队且没在播预览、失败、就绪）时返回 nil，下一次下载重新算。
    static func advance(
        _ track: Track?,
        state: DownloadState,
        progress: Double,
        progressLabel: String,
        isPreviewPlayable: Bool
    ) -> Track? {
        switch state {
        case .downloading:
            break
        case .queued where isPreviewPlayable:
            return track
        default:
            return nil
        }
        let reading = Reading(progressLabel)
        var next = track ?? Track()
        guard reading.hasPercent else { return next }
        let value = clamped(progress)

        let remaining = reading.remainingSeconds ?? 0
        switch next.stage {
        case .waiting:
            next = Track.started(value, remaining: reading.remainingSeconds)
        case .main:
            if value < next.fraction - 0.5 {
                next = afterFileChange(next, value: value, remaining: remaining)
            } else {
                next.fraction = max(next.fraction, value)
                next.longestEstimate = max(next.longestEstimate, remaining)
            }
        case .tail:
            // 慢网络下字幕也可能被当成主文件：收尾里出现比主文件还久的剩余时间，说明真正的视频才开始。
            if remaining >= 2, remaining > next.longestEstimate {
                next = Track(stage: .main, fraction: value, longestEstimate: remaining)
            }
        }
        return next
    }

    /// 主文件期间进度掉了一半以上，换了一个文件。
    private static func afterFileChange(_ track: Track, value: Double, remaining: Int) -> Track {
        if remaining >= 2, remaining > track.longestEstimate {
            // 新文件预计比刚才的还久：刚才是字幕，这个才是视频本体，圆环从它的当前值走起，不再说「准备下载」。
            return Track(stage: .main, fraction: value, longestEstimate: remaining)
        }
        if track.longestEstimate >= 2 {
            // 刚才的文件是视频本体，现在在下音频：保持满格，说「即将完成」。
            return Track(stage: .tail, fraction: 1, longestEstimate: track.longestEstimate)
        }
        // 都是一闪而过的小文件（短片、快网络）：按新文件重新算。
        return Track.started(value, remaining: remaining)
    }

    /// - Parameter track: 这一次下载的记录，见 `advance`；传 nil 时只按这一条读数判断。
    static func model(
        state: DownloadState,
        progress: Double,
        progressLabel: String,
        isPreviewPlayable: Bool,
        track: Track? = nil
    ) -> Model {
        switch state {
        case .ready:
            return Model(phase: .ready, rowText: "", paneTitle: "")
        case .failed:
            return Model(phase: .failed, rowText: progressLabel, paneTitle: "")
        case .queued:
            // 重试倒计时、等网络时预览可能还在播：标记留着，数字停在上次的进度。
            let fraction = track.map(shownFraction)
            let percent = fraction.flatMap { $0 > 0 ? percentValue($0) : nil }
            return Model(
                phase: .queued,
                ringFraction: isPreviewPlayable ? fraction : nil,
                percent: percent,
                rowText: progressLabel,
                paneTitle: "",
                previewBadge: isPreviewPlayable ? badge(percent: percent) : nil
            )
        case .downloading:
            break
        }

        let current = track ?? advance(
            nil,
            state: state,
            progress: progress,
            progressLabel: progressLabel,
            isPreviewPlayable: isPreviewPlayable
        ) ?? Track()

        if current.stage == .waiting {
            let word = statusWord(progressLabel)
            return Model(
                phase: .preparing,
                rowText: isPreviewPlayable ? previewWord : word,
                paneTitle: word,
                previewBadge: isPreviewPlayable ? previewWord : nil
            )
        }

        let fraction = shownFraction(current)
        if fraction >= 0.999 {
            let finishing = isPreviewPlayable ? "\(previewWord) · \(finishingWord)" : finishingWord
            return Model(
                phase: .finishing,
                ringFraction: 1,
                percent: 100,
                rowText: finishing,
                paneTitle: finishingWord,
                previewBadge: isPreviewPlayable ? finishing : nil
            )
        }

        let reading = Reading(progressLabel)
        let percent = percentValue(fraction)
        let detail = [reading.speedText, reading.remainingText].compactMap { $0 }.joined(separator: " · ")
        return Model(
            phase: .downloading,
            ringFraction: fraction,
            percent: percent,
            speedText: reading.speedText,
            remainingText: reading.remainingText,
            rowText: isPreviewPlayable ? "\(previewWord) · \(percent)%" : "\(percent)%",
            paneTitle: savingTitle,
            paneDetail: detail.isEmpty ? nil : detail,
            previewBadge: isPreviewPlayable ? badge(percent: percent) : nil
        )
    }

    /// `6.32MiB/s`、`408.01KiB/s`、`512B/s` 换成每秒字节数；`Unknown B/s` 之类返回 nil。
    static func bytesPerSecond(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("/s") else { return nil }
        let amount = String(trimmed.dropLast(2))
        let units: [(String, Double)] = [
            ("KiB", 1024), ("MiB", 1_048_576), ("GiB", 1_073_741_824),
            ("KB", 1000), ("MB", 1_000_000), ("GB", 1_000_000_000), ("B", 1),
        ]
        for (unit, scale) in units where amount.hasSuffix(unit) {
            let number = amount.dropLast(unit.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value.isFinite, value > 0 else { return nil }
            return value * scale
        }
        return nil
    }

    /// `00:42`、`01:02:03`、`42` 换成秒数；`Unknown`、`NA`、`--:--` 返回 nil。
    static func seconds(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// 速度按 macOS 的十进制单位显示：1 MB/s 以上一位小数，以下取整到 KB/s。
    static func speedText(bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        return "\(max(1, Int((bytesPerSecond / 1000).rounded()))) KB/s"
    }

    /// 剩余时间粗到不跳：5 秒以内不显示；1 分钟以内按 5 秒向上取整；再往上按分钟、小时。
    static func remainingText(seconds: Int) -> String? {
        guard seconds >= 5 else { return nil }
        if seconds < 60 {
            let rounded = Int((Double(seconds) / 5).rounded(.up)) * 5
            return rounded >= 60 ? "剩余 1 分钟" : "剩余 \(rounded) 秒"
        }
        if seconds < 3600 {
            return "剩余 \(Int((Double(seconds) / 60).rounded(.up))) 分钟"
        }
        var hours = seconds / 3600
        var minutes = Int((Double(seconds % 3600) / 60).rounded(.up))
        if minutes == 60 {
            hours += 1
            minutes = 0
        }
        return minutes > 0 ? "剩余 \(hours) 小时 \(minutes) 分" : "剩余 \(hours) 小时"
    }

    private struct Reading {
        var hasPercent = false
        var speedText: String?
        var remainingSeconds: Int?

        var remainingText: String? {
            remainingSeconds.flatMap { DownloadProgressDisplay.remainingText(seconds: $0) }
        }

        init(_ label: String) {
            for field in label.components(separatedBy: " · ") {
                let value = field.trimmingCharacters(in: .whitespaces)
                if DownloadProgressDisplay.isPercent(value) {
                    hasPercent = true
                } else if value.hasPrefix("剩余 ") {
                    remainingSeconds = DownloadProgressDisplay.seconds(String(value.dropFirst(3)))
                } else if let bytes = DownloadProgressDisplay.bytesPerSecond(value) {
                    speedText = DownloadProgressDisplay.speedText(bytesPerSecond: bytes)
                }
            }
        }
    }

    private static func shownFraction(_ track: Track) -> Double {
        track.stage == .tail ? 1 : track.fraction
    }

    private static func isPercent(_ value: String) -> Bool {
        guard value.hasSuffix("%") else { return false }
        let number = value.dropLast()
        return !number.isEmpty && number.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } && Double(number) != nil
    }

    /// 「准备下载…」「继续下载…」「下载中…」去掉省略号做状态词。
    /// 带百分比的读数（字幕文件、视频开头的 0.0%）和 `N/A% · Unknown B/s` 之类不是状态词，统一说「准备下载」。
    private static func statusWord(_ label: String) -> String {
        var word = label.trimmingCharacters(in: .whitespaces)
        if ["%", "·", "/s", "剩余"].contains(where: { word.contains($0) }) {
            return preparingWord
        }
        while word.hasSuffix("…") || word.hasSuffix(".") {
            word.removeLast()
        }
        return word.isEmpty ? preparingWord : word
    }

    private static func badge(percent: Int?) -> String {
        percent.map { "\(previewWord) \($0)%" } ?? previewWord
    }

    private static func percentValue(_ fraction: Double) -> Int {
        min(100, Int((fraction * 100 + 1e-6).rounded(.down)))
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
