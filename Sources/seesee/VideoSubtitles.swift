import Foundation

struct VideoSubtitleCue: Equatable, Identifiable, Sendable {
    let startTime: Double
    let endTime: Double
    let text: String

    /// 播放器用 cue 身份区分连续字幕。仅比较文字会把相同文本的不同时间段误认为同一条。
    var id: VideoSubtitleCueID {
        VideoSubtitleCueID(startTime: startTime, endTime: endTime, text: text)
    }
}

struct VideoSubtitleCueID: Hashable, Sendable {
    let startTime: Double
    let endTime: Double
    let text: String
}

struct VideoSubtitlePresentation: Equatable, Identifiable, Sendable {
    let id: VideoSubtitleCueID
    let text: String

    /// 句间空隙低于该时长时延续上一句，避免整条浮层闪没再闪出。
    static let interCueHoldThreshold: Double = 1.0

    static func resolve(
        track: VideoSubtitleTrack?,
        isEnabled: Bool,
        at time: Double
    ) -> VideoSubtitlePresentation? {
        resolve(track: track, mode: isEnabled ? .bilingual : .off, at: time)
    }

    static func resolve(
        track: VideoSubtitleTrack?,
        mode: SubtitleDisplayMode,
        at time: Double
    ) -> VideoSubtitlePresentation? {
        guard mode != .off, let track, time.isFinite else { return nil }
        let cue = track.cue(at: time) ?? holdOverCue(track: track, at: time)
        guard let cue else { return nil }
        return applying(mode, to: presentation(for: cue))
    }

    /// CJK 统一汉字基本区 U+4E00–U+9FFF 与扩展 A 区 U+3400–U+4DBF。
    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    /// 仅译文档：丢掉原文行只留译文；没有译文的 cue（纯外文原文轨）不显示。
    /// 折叠后只剩一行时，含汉字则视为译文并显示（中文原声、机翻中文轨）。
    private static func applying(
        _ mode: SubtitleDisplayMode,
        to presentation: VideoSubtitlePresentation
    ) -> VideoSubtitlePresentation? {
        guard mode == .translationOnly else { return presentation }
        let lines = displayLines(from: presentation.text)
        if lines.count == 1 {
            return containsHan(lines[0]) ? presentation : nil
        }
        return VideoSubtitlePresentation(
            id: presentation.id,
            text: lines.dropFirst().joined(separator: "\n")
        )
    }

    /// 连续相同行折叠为一行：原文与译文相同时只显示一次。
    static func displayLines(from text: String) -> [String] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        unique.reserveCapacity(lines.count)
        for line in lines where unique.last != line {
            unique.append(line)
        }
        return unique
    }

    static func displayText(from text: String) -> String {
        displayLines(from: text).joined(separator: "\n")
    }

    private static func presentation(for cue: VideoSubtitleCue) -> VideoSubtitlePresentation {
        VideoSubtitlePresentation(id: cue.id, text: displayText(from: cue.text))
    }

    private static func holdOverCue(
        track: VideoSubtitleTrack,
        at time: Double
    ) -> VideoSubtitleCue? {
        let previous = track.cues.last { $0.endTime <= time }
        guard let previous else { return nil }
        let next = track.cues.first { $0.startTime >= time }
        guard let next else { return nil }
        let gap = next.startTime - previous.endTime
        guard gap > 0, gap <= interCueHoldThreshold, time < next.startTime else { return nil }
        return previous
    }
}

/// 字幕浮层的三档显示：双语、仅译文、关；按钮按此顺序循环，逐视频记忆。
enum SubtitleDisplayMode: String, CaseIterable, Sendable {
    case bilingual
    case translationOnly
    case off

    var next: SubtitleDisplayMode {
        switch self {
        case .bilingual: return .translationOnly
        case .translationOnly: return .off
        case .off: return .bilingual
        }
    }
}

/// 逐视频的字幕档位记忆；没记过的视频沿用旧全局开关的默认。
enum SubtitleModeStore {
    private static let key = "subtitleModePerVideo"
    private static let legacyKey = "subtitlesEnabled"

    static func mode(for id: UUID) -> SubtitleDisplayMode {
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if let raw = dict[id.uuidString], let mode = SubtitleDisplayMode(rawValue: raw) {
            return mode
        }
        return UserDefaults.standard.bool(forKey: legacyKey) ? .bilingual : .off
    }

    static func set(_ mode: SubtitleDisplayMode, for id: UUID) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        dict[id.uuidString] = mode.rawValue
        UserDefaults.standard.set(dict, forKey: key)
    }
}

/// 整条浮层的淡入淡出只发生在「无字幕 ↔ 有字幕」边界；句间换字不改透明度。
enum SubtitleOverlayChromeAnimation: Equatable {
    case fadeIn
    case fadeOut
    case replace

    static func resolve(
        from previous: VideoSubtitlePresentation?,
        to next: VideoSubtitlePresentation?
    ) -> SubtitleOverlayChromeAnimation {
        switch (previous, next) {
        case (nil, .some):
            return .fadeIn
        case (.some, nil):
            return .fadeOut
        case (.some, .some):
            return .replace
        case (nil, nil):
            return .fadeOut
        }
    }
}

struct VideoSubtitleTrack: Equatable, Sendable {
    let cues: [VideoSubtitleCue]

    init(cues: [VideoSubtitleCue]) {
        self.cues = cues
    }

    init?(contentsOf url: URL) {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = Self.parse(source)
        guard !parsed.isEmpty else { return nil }
        cues = parsed
    }

    func cue(at time: Double) -> VideoSubtitleCue? {
        guard time.isFinite else { return nil }
        let active = cues.filter { $0.startTime <= time && time < $0.endTime }
        return active.max(by: { $0.startTime < $1.startTime })
    }

    func text(at time: Double) -> String? {
        cue(at: time)?.text
    }

    func cues(around time: Double, window: Double) -> [VideoSubtitleCue] {
        guard time.isFinite, window.isFinite, window >= 0 else { return [] }
        let start = time - window
        let end = time + window
        return cues.filter { $0.endTime >= start && $0.startTime <= end }
    }

    /// 短于该时长且紧邻后续更长 cue 的条目视为 YouTube 滚动字幕闪现帧，从列表中折叠。
    private static let rollingFlashDurationThreshold: Double = 0.05
    /// 闪现 cue 结束与下一条开始之间允许的空隙（含时间戳四舍五入误差）。
    private static let rollingFlashGapTolerance: Double = 0.05

    static func parse(_ source: String) -> [VideoSubtitleCue] {
        let raw = parseBlocks(source).sorted { lhs, rhs in
            lhs.startTime == rhs.startTime ? lhs.endTime < rhs.endTime : lhs.startTime < rhs.startTime
        }
        return unrollRollingLineCues(collapseRollingFlashCues(raw))
    }

    /// 按「下一条序号/时间轴」切块，保住时间轴后的空行（两行窗第一行空白）。
    static func parseBlocks(_ source: String) -> [VideoSubtitleCue] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var cues: [VideoSubtitleCue] = []
        var index = 0
        while index < lines.count {
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            guard index < lines.count else { break }
            if isIndexLine(lines[index]),
               index + 1 < lines.count,
               lines[index + 1].contains("-->") {
                index += 1
            }
            guard index < lines.count, lines[index].contains("-->") else {
                index += 1
                continue
            }
            let timing = lines[index].components(separatedBy: "-->")
            index += 1
            var body: [String] = []
            while index < lines.count, !isCueHeader(lines, at: index) {
                body.append(lines[index])
                index += 1
            }
            guard timing.count == 2,
                  let start = parseTimestamp(timing[0]),
                  let end = parseTimestamp(timing[1]),
                  end > start else { continue }
            let caption = cleanCaption(body.joined(separator: "\n"))
            guard !caption.isEmpty else { continue }
            cues.append(VideoSubtitleCue(startTime: start, endTime: end, text: caption))
        }
        return cues
    }

    private static func isIndexLine(_ line: String) -> Bool {
        let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return !token.isEmpty && token.allSatisfy(\.isNumber)
    }

    private static func isCueHeader(_ lines: [String], at index: Int) -> Bool {
        var cursor = index
        while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
            cursor += 1
        }
        guard cursor < lines.count else { return false }
        if lines[cursor].contains("-->") { return true }
        return isIndexLine(lines[cursor])
            && cursor + 1 < lines.count
            && lines[cursor + 1].contains("-->")
    }

    /// 相邻两条上一行与下一行正文完全相同，视为两行滚动窗在推进。
    static func isRollingAdvance(_ previous: VideoSubtitleCue, _ current: VideoSubtitleCue) -> Bool {
        guard let last = captionLines(previous).last, let first = captionLines(current).first else {
            return false
        }
        return last == first
    }

    /// 只拆滚动推进的连续段；双语整窗（行与行不完全相同）原样保留。
    static func unrollRollingLineCues(_ cues: [VideoSubtitleCue]) -> [VideoSubtitleCue] {
        guard cues.count > 1 else { return cues }
        var result: [VideoSubtitleCue] = []
        var runStart = 0
        while runStart < cues.count {
            var runEnd = runStart
            while runEnd + 1 < cues.count, isRollingAdvance(cues[runEnd], cues[runEnd + 1]) {
                runEnd += 1
            }
            if runEnd > runStart {
                result.append(contentsOf: unrollRun(Array(cues[runStart...runEnd])))
            } else {
                result.append(cues[runStart])
            }
            runStart = runEnd + 1
        }
        return result
    }

    private static func captionLines(_ cue: VideoSubtitleCue) -> [String] {
        cue.text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func unrollRun(_ run: [VideoSubtitleCue]) -> [VideoSubtitleCue] {
        var firstSeen: [String: Double] = [:]
        var emitted: [VideoSubtitleCue] = []
        var previous: [String] = []
        for cue in run {
            let current = captionLines(cue)
            for line in current where firstSeen[line] == nil {
                firstSeen[line] = cue.startTime
            }
            for line in previous where !current.contains(line) {
                if let start = firstSeen.removeValue(forKey: line), cue.startTime > start {
                    emitted.append(VideoSubtitleCue(startTime: start, endTime: cue.startTime, text: line))
                }
            }
            previous = current
        }
        if let last = run.last {
            for line in previous {
                if let start = firstSeen[line], last.endTime > start {
                    emitted.append(VideoSubtitleCue(startTime: start, endTime: last.endTime, text: line))
                }
            }
        }
        return emitted.sorted { lhs, rhs in
            lhs.startTime == rhs.startTime ? lhs.endTime < rhs.endTime : lhs.startTime < rhs.startTime
        }
    }

    /// 去掉 YouTube 自动字幕的「10ms 闪现 + 扩展句」成对重复，保留双语两行完整 cue。
    /// 除时长/邻接外必须核对文本连续性：闪现须与下一条相同、为其前缀，或为其子集（滚动窗）；
    /// 内容无关的短 cue（如音效标注）一律保留。
    static func collapseRollingFlashCues(_ cues: [VideoSubtitleCue]) -> [VideoSubtitleCue] {
        guard cues.count > 1 else { return cues }
        var kept: [VideoSubtitleCue] = []
        kept.reserveCapacity(cues.count)
        var index = 0
        while index < cues.count {
            let cue = cues[index]
            let duration = cue.endTime - cue.startTime
            if duration < rollingFlashDurationThreshold, index + 1 < cues.count {
                let next = cues[index + 1]
                let gap = next.startTime - cue.endTime
                let nextDuration = next.endTime - next.startTime
                // 时长邻接 + 文本连续（相同 / 前缀 / 子集）才折叠。
                if gap >= -0.001,
                   gap < rollingFlashGapTolerance,
                   nextDuration > duration,
                   isRollingFlashContinuation(cue.text, of: next.text) {
                    index += 1
                    continue
                }
            }
            kept.append(cue)
            index += 1
        }
        return kept
    }

    /// 判断极短 cue 是否为下一条的滚动闪现（文本相同、前缀或子集），而非独立内容。
    static func isRollingFlashContinuation(_ flash: String, of next: String) -> Bool {
        if flash == next { return true }
        if next.hasPrefix(flash) { return true }

        let flashLines = flash
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let nextLines = next
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let flashFirst = flashLines.first, let nextFirst = nextLines.first else { return false }

        // 原文首行扩展：YouTube 滚动主轨几乎总是首行前缀关系。
        if nextFirst.hasPrefix(flashFirst) { return true }

        // 逐行前缀：闪现各行是下一条对应行的前缀（双语两行同时扩展）。
        if flashLines.count <= nextLines.count,
           zip(flashLines, nextLines).allSatisfy({ flashLine, nextLine in
               nextLine.hasPrefix(flashLine)
           }) {
            return true
        }

        // 去换行后的前缀 / 连续子串子集（行切分不一致时）。
        let flashJoined = flashLines.joined(separator: " ")
        let nextJoined = nextLines.joined(separator: " ")
        if nextJoined.hasPrefix(flashJoined) { return true }
        if !flashJoined.isEmpty, nextJoined.contains(flashJoined) { return true }

        return false
    }

    private static func parseTimestamp(_ rawValue: String) -> Double? {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first?
            .replacingOccurrences(of: ",", with: ".") ?? ""
        let fields = token.split(separator: ":").compactMap { Double($0) }
        switch fields.count {
        case 3:
            return fields[0] * 3_600 + fields[1] * 60 + fields[2]
        case 2:
            return fields[0] * 60 + fields[1]
        default:
            return nil
        }
    }

    private static func cleanCaption(_ rawValue: String) -> String {
        var value = rawValue
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]+\}"#, with: "", options: .regularExpression)
        let entities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&#x27;": "'",
            "&nbsp;": " ",
            "&lrm;": "",
            "&rlm;": ""
        ]
        for (entity, replacement) in entities {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value.components(separatedBy: "\n")
            .map {
                $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
