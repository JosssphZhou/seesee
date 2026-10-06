import AVFoundation
import Foundation
import NaturalLanguage
import Speech
import Translation

/// Apple 的文件转写与离线初译；串行调度由 QueueStore 负责。
@available(macOS 26, *)
enum LocalTranscription {
    struct Files: Sendable {
        let original: URL
        let initial: URL?
        let language: String
        let languageFallback: Bool
    }
    enum Phase: Sendable {
        case detected(language: String, fallback: Bool)
        case originalReady(URL)
        case translating
    }
    struct Failed: Error, LocalizedError {
        let message: String
        var code: String = "processing_failed"
        var errorDescription: String? { message }
    }
    private struct Word: Sendable {
        let text: String
        let start: Double
        let end: Double
        let confidence: Double?
    }

    static func run(movie: URL, itemID: UUID, folder: URL, existingOriginal: URL? = nil,
                    language: String? = nil, languageFallback: Bool = false,
                    phase: @escaping @Sendable (Phase) async throws -> Void) async throws -> Files {
        let original: URL
        let cues: [VideoSubtitleCue]
        let source: String
        let fallback: Bool
        if let existingOriginal, let language, let track = VideoSubtitleTrack(contentsOf: existingOriginal) {
            original = existingOriginal
            cues = track.cues
            source = language
            fallback = languageFallback
        } else {
            guard SpeechTranscriber.isAvailable else { throw Failed(message: "系统语音转写当前不可用") }
            guard await AppleSpeechAssets.areInstalled() else {
                throw Failed(message: "请先在设置页下载中英文语音模型", code: "speech_assets_missing")
            }
            guard let resources = Bundle.main.resourceURL else { throw Failed(message: "找不到应用内置音频工具") }
            let ffmpeg = resources.appendingPathComponent("Tools/ffmpeg")
            guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
                throw Failed(message: "应用缺少音频处理组件，无法转写")
            }
            let scratch = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ss-asr-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let probe = scratch.appendingPathComponent("probe.wav")
            try await extract(movie, to: probe, ffmpeg: ffmpeg, seconds: 12)
            let locales = try await AppleSpeechAssets.locales()
            let english = try await recognize(probe, locale: locales[0])
            let chinese = try await recognize(probe, locale: locales[1])
            let choice = chooseLanguage(english: english, chinese: chinese)
            source = choice.language
            fallback = choice.fallback
            try await phase(.detected(language: source, fallback: fallback))
            let audio = scratch.appendingPathComponent("full.wav")
            try await extract(movie, to: audio, ffmpeg: ffmpeg)
            let words = try await recognize(audio, locale: locales[source == "zh" ? 1 : 0])
            cues = sentences(words, language: source)
            guard !cues.isEmpty else { throw Failed(message: "没有识别到语音") }
            original = folder.appendingPathComponent("\(itemID.uuidString).original-\(UUID().uuidString).vtt")
            try Task.checkCancellation()
            try SubtitleVersionStore.write(cues, to: original)
        }
        try await phase(.originalReady(original))
        if source == "zh" {
            return Files(original: original, initial: nil, language: source, languageFallback: fallback)
        }
        try await phase(.translating)
        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
        guard await session.isReady else { throw Failed(message: "本机翻译语言包未安装，原文字幕已保留", code: "translation_assets_missing") }
        var bilingual: [VideoSubtitleCue] = []
        for cue in cues {
            try Task.checkCancellation()
            // 包括最后被截断的半句话：只翻给出的原文，输入不添加后续内容。
            let response = try await session.translate(cue.text)
            let translated = response.targetText.components(separatedBy: .newlines).joined(separator: " ")
            bilingual.append(VideoSubtitleCue(startTime: cue.startTime, endTime: cue.endTime,
                                               text: cue.text + "\n" + translated, isSentenceBlock: true))
        }
        let initial = folder.appendingPathComponent("\(itemID.uuidString).initial-\(UUID().uuidString).vtt")
        try Task.checkCancellation()
        try SubtitleVersionStore.write(bilingual, to: initial)
        return Files(original: original, initial: initial, language: source, languageFallback: fallback)
    }

    private static func extract(_ movie: URL, to output: URL, ffmpeg: URL, seconds: Double? = nil) async throws {
        let worker = Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = ffmpeg
            var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "1", "-i", movie.path]
            if let seconds { arguments += ["-t", String(seconds)] }
            arguments += ["-vn", "-ac", "1", "-ar", "16000", "-n", output.path]
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try process.run()
                process.waitUntilExit()
                try Task.checkCancellation()
                guard process.terminationStatus == 0 else { throw Failed(message: "提取音频失败") }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func recognize(_ audio: URL, locale: Locale) async throws -> [Word] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters)
                    let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] ?? result.range
                    let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                    guard range.start.seconds.isFinite, range.end.seconds.isFinite, range.end.seconds >= range.start.seconds else { continue }
                    words.append(Word(text: text, start: max(0, range.start.seconds), end: range.end.seconds, confidence: confidence))
                }
            }
            return words
        }
        do {
            return try await withTaskCancellationHandler {
                try await analyzer.start(inputAudioFile: AVAudioFile(forReading: audio), finishAfterFile: true)
                return try await collector.value
            } onCancel: {
                collector.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func chooseLanguage(english: [Word], chinese: [Word]) -> (language: String, fallback: Bool) {
        func score(_ words: [Word], expected: NLLanguage) -> Double {
            let text = words.map(\.text).joined()
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else { return 0 }
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [.english, .simplifiedChinese]
            recognizer.processString(text)
            let plausibility = recognizer.languageHypotheses(withMaximum: 2)[expected] ?? 0
            let values = words.compactMap(\.confidence)
            let confidence = values.isEmpty ? 0.5 : values.reduce(0, +) / Double(values.count)
            return confidence * plausibility
        }
        let en = score(english, expected: .english)
        let zh = score(chinese, expected: .simplifiedChinese)
        guard max(en, zh) >= 0.45, abs(en - zh) >= 0.08 else { return ("en", true) }
        return (zh > en ? "zh" : "en", false)
    }

    /// 用系统句子边界切文本，时间取覆盖该句的原生词级时间范围。
    private static func sentences(_ words: [Word], language: String) -> [VideoSubtitleCue] {
        var text = ""
        var ranges: [(NSRange, Word)] = []
        for word in words {
            let start = text.utf16.count
            text += word.text
            ranges.append((NSRange(location: start, length: word.text.utf16.count), word))
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(language == "zh" ? .simplifiedChinese : .english)
        var cues: [VideoSubtitleCue] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let token = NSRange(range, in: text)
            let matching = ranges.filter { NSIntersectionRange($0.0, token).length > 0 }.map { $0.1 }
            if !sentence.isEmpty, let start = matching.map(\.start).min(), let end = matching.map(\.end).max(), end > start {
                cues.append(VideoSubtitleCue(startTime: start, endTime: end, text: sentence, isSentenceBlock: true))
            }
            return true
        }
        return cues
    }
}
