import CryptoKit
import Foundation

/// 不可变字幕版本：编号和时间取首次字幕，文字取活动版本，修订凭据也覆盖文件内容。
enum SubtitleVersionStore {
    struct Failure: Error, LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }
    struct Translation: Sendable {
        let index: Int
        let translation: String?
        let original: String?
        init(index: Int, translation: String? = nil, original: String? = nil) {
            self.index = index; self.translation = translation; self.original = original
        }
    }
    struct Snapshot {
        let revision: String
        let cues: [VideoSubtitleCue]
        var translationOnly: Bool = false
    }

    static func snapshot(_ item: WatchItem) throws -> Snapshot {
        guard let active = item.subtitleFilePath, !active.isEmpty else { throw noSubtitles() }
        let initial = item.initialSubtitlePath ?? active
        let original = item.originalSubtitlePath ?? initial
        let paths = [original, initial, active]
        let bytes: [Data]
        do { bytes = try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } }
        catch { throw noSubtitles() }
        guard let initialTrack = VideoSubtitleTrack(contentsOf: URL(fileURLWithPath: initial)),
              let activeTrack = VideoSubtitleTrack(contentsOf: URL(fileURLWithPath: active)) else { throw noSubtitles() }
        let translationOnly = item.originalSubtitlePath == nil && item.translationSource != nil && initialTrack.cues.allSatisfy { split($0).translation == nil }
        let initialBlocks = try initialCues(item)
        // 外置或旧分轨条目可能直接指向初译原轨；其活动内容就是按原文配好的首次句块。
        let currentBlocks = active == initial ? initialBlocks : SubtitleSentenceBlocks.aggregate(activeTrack.cues)
        guard initialBlocks.count == currentBlocks.count else {
            throw Failure(code: "subtitles_changed", message: "活动字幕句数与首次字幕不同，请重新读取字幕")
        }
        let cues = try zip(initialBlocks, currentBlocks).map { initial, current -> VideoSubtitleCue in
            guard initial.startTime == current.startTime, initial.endTime == current.endTime,
                  (translationOnly || item.originalCorrectable || split(initial).original == split(current).original) else {
                throw Failure(code: "subtitles_changed", message: "原文或时间戳已经改变，请重新读取字幕")
            }
            let lines = translationOnly ? [current.text] : [item.originalCorrectable ? split(current).original : split(initial).original, split(current).translation].compactMap { $0 }.filter { !$0.isEmpty }
            return VideoSubtitleCue(startTime: initial.startTime, endTime: initial.endTime, text: lines.joined(separator: "\n"), isSentenceBlock: true)
        }
        var hash = SHA256()
        // Length prefixes prevent boundaries in different files from sharing one revision.
        for data in [Data(String(item.subtitleRevision ?? 0).utf8)] + bytes {
            hash.update(data: Data("\(data.count):".utf8))
            hash.update(data: data)
        }
        let revision = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return Snapshot(revision: revision, cues: cues, translationOnly: translationOnly)
    }

    static func writing(_ translations: [Translation], revision: String, item: WatchItem) throws -> WatchItem {
        let correctsOriginal = translations.contains { $0.original != nil }
        let polishesTranslation = translations.contains { $0.translation != nil }
        if correctsOriginal, !item.originalCorrectable {
            throw Failure(code: "original_not_correctable", message: "只有苹果本机转写的原文可以纠正，下载站点给的原文不能修改")
        }
        if polishesTranslation, !item.translationPolishable { throw notPolishable() }
        guard correctsOriginal || polishesTranslation else { throw invalid("每句须提供原文或译文") }
        let snapshot = try snapshot(item)
        guard revision == snapshot.revision else {
            throw Failure(code: "subtitles_changed", message: "读取后字幕版本已经改变，请重新读取整轨再写回")
        }
        guard translations.count == snapshot.cues.count else { throw invalid("必须一次写全整轨字幕") }
        var indexed: [Int: Translation] = [:]
        for value in translations {
            guard snapshot.cues.indices.contains(value.index), indexed[value.index] == nil else { throw invalid("字幕编号越界或重复") }
            guard value.original != nil || value.translation != nil else { throw invalid("index \(value.index) 须提供原文或译文") }
            for (label, text) in [("原文", value.original), ("译文", value.translation)] {
                if let text { try validate(text, label: label, index: value.index) }
            }
            indexed[value.index] = value
        }
        let cues = snapshot.cues.enumerated().map { index, cue in
            let value = indexed[index]!, current = split(cue)
            let original = value.original ?? current.original
            let translation = value.translation ?? current.translation
            let text = snapshot.translationOnly ? (value.translation ?? cue.text) : [original, translation].compactMap { $0 }.joined(separator: "\n")
            return VideoSubtitleCue(startTime: cue.startTime, endTime: cue.endTime, text: text, isSentenceBlock: true)
        }
        // 两个单行拼在一起也须精确往返，避免跨行的字幕标记被解析器剃掉。
        let parsed = VideoSubtitleTrack.parse(String(decoding: encoded(cues), as: UTF8.self))
        guard parsed.count == cues.count else {
            let index = cues.indices.first { index in
                !parsed.indices.contains(index)
                    || parsed[index].startTime != cues[index].startTime
                    || parsed[index].endTime != cues[index].endTime
                    || parsed[index].text != cues[index].text
            } ?? max(0, cues.count - 1)
            let reason = cues.indices.contains(index + 1) && cues[index].text == cues[index + 1].text
                ? "。相邻两句文字完全相同会被合并，可以保留原来的标点区分" : ""
            throw invalid("index \(index) 的原文和译文组合会改变字幕结构\(reason)")
        }
        for index in cues.indices where parsed[index].text != cues[index].text {
            throw invalid("index \(index) 的原文和译文组合会被字幕解析器改写")
        }
        var updated = item
        updated.originalSubtitlePath = snapshot.translationOnly ? nil : (item.originalSubtitlePath ?? item.subtitleFilePath)
        updated.initialSubtitlePath = item.initialSubtitlePath ?? item.subtitleFilePath
        updated.initialTranslationSource = item.initialTranslationSource ?? item.translationSource
        updated.subtitleRevision = (item.subtitleRevision ?? 0) + 1
        let folder = URL(fileURLWithPath: updated.initialSubtitlePath!).deletingLastPathComponent()
        let path = folder.appendingPathComponent("\(item.id.uuidString).agent-\(updated.subtitleRevision!)-\(UUID().uuidString).vtt")
        try write(cues, to: path)
        updated.subtitleFilePath = path.path
        if correctsOriginal { updated.originalSubtitleSource = "apple" }
        if polishesTranslation { updated.translationSource = "agent" }
        return updated
    }

    static func restoring(_ item: WatchItem) throws -> WatchItem {
        guard item.translationPolishable || item.originalCorrectable else { throw notPolishable() }
        guard let initial = item.initialSubtitlePath ?? item.subtitleFilePath,
              VideoSubtitleTrack(contentsOf: URL(fileURLWithPath: initial)) != nil else { throw noSubtitles() }
        var updated = item
        updated.subtitleFilePath = initial
        // 分轨初译的显示文件可复用；比对实际内容，不能误用另一次初译的显示轨。
        if let original = item.originalSubtitlePath, original != initial,
           let track = VideoSubtitleTrack(contentsOf: URL(fileURLWithPath: initial)), track.cues.allSatisfy({ split($0).translation == nil }) {
            let folder = URL(fileURLWithPath: initial).deletingLastPathComponent()
            let cues = try initialCues(item), contents = encoded(cues)
            let prefix = "\(item.id.uuidString).initial-display-"
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "vtt" }.sorted { $0.path < $1.path }
            let current = item.subtitleFilePath.map { URL(fileURLWithPath: $0) }
            let candidates = (current.map { [$0] } ?? []) + files
            let display: URL
            if let cached = candidates.first(where: { $0.lastPathComponent.hasPrefix(prefix) && (try? Data(contentsOf: $0)) == contents }) {
                display = cached
            } else {
                display = folder.appendingPathComponent("\(prefix)\(UUID().uuidString).vtt")
                try write(cues, to: display)
            }
            updated.subtitleFilePath = display.path
        }
        updated.initialSubtitlePath = initial
        updated.initialTranslationSource = item.initialTranslationSource ?? item.translationSource
        updated.translationSource = updated.initialTranslationSource
        if updated.subtitleFilePath == item.subtitleFilePath, updated.translationSource == item.translationSource {
            return item
        }
        updated.subtitleRevision = (item.subtitleRevision ?? 0) + 1
        return updated
    }

    /// 首次译文可能是双语文件，也可能是 yt-dlp 下载的独立中文碎片轨。
    static func initialCues(_ item: WatchItem) throws -> [VideoSubtitleCue] {
        guard let path = item.initialSubtitlePath ?? item.subtitleFilePath,
              let initial = VideoSubtitleTrack(contentsOf: URL(fileURLWithPath: path)) else { throw noSubtitles() }
        guard let originalPath = item.originalSubtitlePath, originalPath != path,
              initial.cues.allSatisfy({ split($0).translation == nil }),
              let original = VideoSubtitleTrack(contentsOf: URL(fileURLWithPath: originalPath)) else {
            return SubtitleSentenceBlocks.aggregate(initial.cues)
        }
        let blocks = SubtitleSentenceBlocks.aggregate(original.cues)
        var translated = Array(repeating: [String](), count: blocks.count)
        for cue in initial.cues {
            let overlaps = blocks.map { max(0, min($0.endTime, cue.endTime) - max($0.startTime, cue.startTime)) }
            guard let index = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[index] > 0 else { continue }
            if translated[index].last != cue.text { translated[index].append(cue.text) }
        }
        return blocks.enumerated().map { index, cue in
            let text = translated[index].joined(separator: " ")
            return VideoSubtitleCue(startTime: cue.startTime, endTime: cue.endTime,
                text: split(cue).original + (text.isEmpty ? "" : "\n" + text), isSentenceBlock: true)
        }
    }

    /// 标准 WebVTT，NOTE 标明已经分句，让右栏再次聚合时保持一一对应。
    static func write(_ cues: [VideoSubtitleCue], to url: URL) throws {
        do { try encoded(cues).write(to: url, options: .withoutOverwriting) }
        catch { throw Failure(code: "subtitle_write_failed", message: "无法保存新的字幕文件：\(error.localizedDescription)") }
    }

    private static func encoded(_ cues: [VideoSubtitleCue]) -> Data {
        let body = cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.startTime)) --> \(timestamp(cue.endTime))\n\(cue.text)\n"
        }.joined(separator: "\n")
        return Data(("WEBVTT\n\nNOTE seesee-sentence-blocks-v1\n\n" + body).utf8)
    }

    static func split(_ cue: VideoSubtitleCue) -> (original: String, translation: String?) {
        let lines = cue.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (lines.first ?? "", lines.count > 1 ? lines.dropFirst().joined(separator: " ") : nil)
    }
    private static func validate(_ text: String, label: String, index: Int) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 4000,
              text.rangeOfCharacter(from: .newlines) == nil else {
            throw invalid("index \(index) 的\(label)须为非空单行，且不超过4000字")
        }
        let parsed = VideoSubtitleTrack.parse("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n" + text + "\n")
        guard parsed.count == 1, parsed[0].text == text else {
            throw invalid("index \(index) 的\(label)含字幕标记、实体或会被改写的空白，请改成普通单行文字")
        }
    }
    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
    private static func noSubtitles() -> Failure { Failure(code: "no_subtitles", message: "没有可读取的字幕文件") }
    private static func notPolishable() -> Failure { Failure(code: "translation_not_polishable", message: "人工字幕或没有译文的条目不能润色") }
    private static func invalid(_ text: String) -> Failure { Failure(code: "invalid_arguments", message: text + "，什么都没写") }
}
