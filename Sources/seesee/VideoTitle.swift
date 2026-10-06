import Foundation
import NaturalLanguage

/// 中文译名的来源，存在 `WatchItem.translatedTitleSource` 里。
enum TitleTranslationSource: String, Codable {
    /// 视频作者提供的中文标题（YouTube 的本地化标题）。
    case author
    /// 本机翻译（Apple 翻译框架）。
    case onDevice
}

/// 一条视频的标题怎么显示：主标题，和放在它下面一行的原标题小字，同双语字幕一个思路。
/// 队列行、右栏详情头、播放器标题栏、小窗和 MCP 都用这一套。
struct TitleDisplay: Equatable {
    enum Kind: Equatable {
        case custom
        case translated(TitleTranslationSource)
        case original
    }

    let primary: String
    /// 原标题。主标题就是原标题时为 nil。
    let secondary: String?
    let kind: Kind

    /// 主标题按用户改名、中文译名、原标题的顺序取。原标题去掉开头重复的「作者 - 」。
    static func resolve(
        original: String,
        translated: String?,
        source: TitleTranslationSource?,
        custom: String?,
        author: String
    ) -> TitleDisplay {
        let shownOriginal = QueueRowMeta.displayTitle(title: original, author: author)
        func below(_ primary: String) -> String? {
            let candidate = shownOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, !VideoTitleText.same(candidate, primary) else { return nil }
            return candidate
        }
        if let custom = VideoTitleText.nonEmpty(custom) {
            return TitleDisplay(primary: custom, secondary: below(custom), kind: .custom)
        }
        if let translated = VideoTitleText.nonEmpty(translated), !VideoTitleText.same(translated, original) {
            return TitleDisplay(
                primary: translated,
                secondary: below(translated),
                kind: .translated(source ?? .onDevice)
            )
        }
        return TitleDisplay(primary: shownOriginal, secondary: nil, kind: .original)
    }
}

enum VideoTitleText {
    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// 去掉首尾空白、压缩中间空白、不分大小写以后相同。
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        collapsed(lhs).lowercased() == collapsed(rhs).lowercased()
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

extension WatchItem {
    /// 原标题。旧条目还没迁移时退回 `title`。
    var resolvedOriginalTitle: String { originalTitle ?? title }

    var translationSource: TitleTranslationSource? {
        translatedTitleSource.flatMap(TitleTranslationSource.init(rawValue:))
    }

    var titleDisplay: TitleDisplay {
        TitleDisplay.resolve(
            original: resolvedOriginalTitle,
            translated: translatedTitle,
            source: translationSource,
            custom: customTitle,
            author: author
        )
    }

    /// 旧格式的条目没有原标题：原来的 `title` 当作原标题。旧版本里改过的名字没法区分，也当作原标题。
    mutating func adoptLegacyTitle() {
        if originalTitle == nil { originalTitle = title }
    }

    /// 元数据带来的原标题。空的不写；原标题换了，为旧原标题翻的译名作废。返回原标题有没有变。
    @discardableResult
    mutating func setOriginalTitle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, originalTitle != trimmed else {
            refreshTitle()
            return false
        }
        if originalTitle != nil, translatedTitle != nil {
            translatedTitle = nil
            translatedTitleSource = nil
        }
        originalTitle = trimmed
        refreshTitle()
        return true
    }

    mutating func setTranslatedTitle(_ value: String, source: TitleTranslationSource) {
        guard let trimmed = VideoTitleText.nonEmpty(value) else { return }
        translatedTitle = trimmed
        translatedTitleSource = source.rawValue
        refreshTitle()
    }

    /// 用户改名。空的不改；改成和自动标题一样时清掉改名，以后跟着译名走。返回有没有变。
    @discardableResult
    mutating func rename(to value: String) -> Bool {
        guard let trimmed = VideoTitleText.nonEmpty(value), trimmed != titleDisplay.primary else { return false }
        var automatic = self
        automatic.customTitle = nil
        customTitle = trimmed == automatic.titleDisplay.primary ? nil : trimmed
        refreshTitle()
        return true
    }

    /// 按显示优先级重算 `title`。
    mutating func refreshTitle() {
        title = VideoTitleText.nonEmpty(customTitle)
            ?? VideoTitleText.nonEmpty(translatedTitle)
            ?? VideoTitleText.nonEmpty(originalTitle)
            ?? title
    }
}

/// X 视频的标题：yt-dlp 把推文截到 72 个字符再拼上作者名，完整正文在 description 里。
/// 原标题用正文去掉链接后的第一句，太短就接下一句；正文为空时用「作者的视频」。
enum XPostTitle {
    /// 第一句里字母、数字和汉字少于这个数（话题标签和 @ 不算）就接下一句。
    static let minimumMeaningfulCharacters = 6

    static func title(postText: String?, author: String) -> String {
        let text = cleaned(postText ?? "")
        guard !text.isEmpty else { return emptyTitle(author: author) }
        let sentences = sentences(in: text)
        guard var result = sentences.first else { return emptyTitle(author: author) }
        for next in sentences.dropFirst() where meaningfulCount(result) < minimumMeaningfulCharacters {
            result = joined(result, next)
        }
        return result
    }

    static func emptyTitle(author: String) -> String {
        let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "推文里的视频" : "\(name)的视频"
    }

    /// X 给的推文正文把 & < > 引号写成 HTML 转义（`&amp;`），还原成原来的字符。
    static func unescaped(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 去掉链接，压缩空白，去掉首尾空白。
    static func cleaned(_ text: String) -> String {
        let withoutLinks = text.replacingOccurrences(
            of: #"(?:https?://|www\.)\S+"#,
            with: " ",
            options: .regularExpression
        )
        return VideoTitleText.collapsed(withoutLinks)
    }

    private static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result.isEmpty ? [text] : result
    }

    private static func meaningfulCount(_ text: String) -> Int {
        let withoutTags = text.replacingOccurrences(of: #"[#@＃]\S+"#, with: " ", options: .regularExpression)
        return withoutTags.filter { $0.isLetter || $0.isNumber }.count
    }

    private static func joined(_ lhs: String, _ rhs: String) -> String {
        guard let last = lhs.unicodeScalars.last, let first = rhs.unicodeScalars.first else { return lhs + rhs }
        return TitleLanguage.isCJK(last) || TitleLanguage.isCJK(first) ? lhs + rhs : lhs + " " + rhs
    }
}

/// 标题是什么语言、要不要翻。
enum TitleLanguage {
    /// 短标题上识别器常把英文认成荷兰语、西班牙语，先给常见语言一个底分。
    private static let baseHints: [NLLanguage: Double] = [
        .english: 0.5,
        .simplifiedChinese: 0.1,
        .traditionalChinese: 0.05,
        .japanese: 0.1,
        .korean: 0.05,
        .french: 0.05,
        .german: 0.05,
        .spanish: 0.05
    ]

    /// 本来就是中文（简体或繁体）的标题不翻。没有任何文字的也不翻。
    static func needsTranslation(_ text: String) -> Bool {
        guard text.contains(where: { $0.isLetter }) else { return false }
        return !isChinese(text)
    }

    static func isChinese(_ text: String) -> Bool {
        guard let language = recognize(text, hint: nil) else { return false }
        return language == .simplifiedChinese || language == .traditionalChinese
    }

    /// 翻译时给的源语言，不会是空的：先看标题本身，再参考 yt-dlp 给的视频语言，都没有时按英文。
    static func sourceLanguage(for text: String, hint: String?) -> String {
        if let language = recognize(text, hint: hint) { return language.rawValue }
        return baseCode(hint) ?? "en"
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    private static func recognize(_ text: String, hint: String?) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        var hints = baseHints
        if let code = baseCode(hint) {
            let language = code == "zh" ? NLLanguage.simplifiedChinese : NLLanguage(rawValue: code)
            hints[language, default: 0] += 0.4
        }
        recognizer.languageHints = hints
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    /// yt-dlp 的语言字段可能是 en、en-US、zh-Hans 之类，取主语言；「und」等占位不算。
    private static func baseCode(_ hint: String?) -> String? {
        guard let hint = VideoTitleText.nonEmpty(hint)?.lowercased(),
              let code = hint.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init),
              code.count >= 2, code.count <= 3, code != "und", code != "mul", code != "zxx" else { return nil }
        return code
    }
}

/// 作者提供的中文标题（YouTube 本地化标题）什么时候用。
enum AuthorTitle {
    /// 本地化标题是中文、和原标题不同，而且原标题本身不是中文时才用。
    static func accepts(localized: String, original: String) -> Bool {
        guard let localized = VideoTitleText.nonEmpty(localized) else { return false }
        guard !VideoTitleText.same(localized, original) else { return false }
        return TitleLanguage.isChinese(localized) && !TitleLanguage.isChinese(original)
    }
}

extension WatchItem {
    var isXPost: Bool { sourceName == "X" }

    /// 元数据到达时写原标题。X 视频用推文正文的第一句，并另存推文全文；其他网站用 yt-dlp 的标题。
    /// 只写原标题和推文全文，不碰用户改名。
    mutating func applyMetadataTitle(title: String, postText: String?, author: String) {
        if isXPost {
            // 正文缺失（null）和空正文一样处理，用「作者的视频」兜底。
            let full = XPostTitle.unescaped(postText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.postText = full.isEmpty ? nil : full
            setOriginalTitle(XPostTitle.title(postText: full, author: author))
        } else {
            setOriginalTitle(title)
        }
    }
}

/// 标题分开存以后第一次保存前，把旧版本写的 queue.json 原样复制一份留在同目录。
enum TitleFieldsMigration {
    /// 不用片库搬移的 `queue.json.bak-` 前缀：搬移按那个前缀找自己的备份，混进来会被当成搬移备份。
    static let backupPrefix = "queue-标题升级前备份-"

    enum Outcome: Equatable {
        /// 已经是新格式，不用备份。
        case notNeeded
        case backedUp(URL)
        /// 要备份但没写成：调用方在备份成功之前不能用新格式覆盖 queue.json。
        case failed
    }

    /// 有条目还没有 `originalTitle`（旧版本写的）时才复制；同名文件已存在就换个名字，不覆盖。
    @discardableResult
    static func backUpIfLegacy(_ data: Data, beside dataFile: URL, now: Date = Date()) -> Outcome {
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              objects.contains(where: { $0["originalTitle"] == nil }) else { return .notNeeded }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = dataFile.deletingLastPathComponent()
        let base = backupPrefix + formatter.string(from: now)
        var name = base + ".json"
        var suffix = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(suffix).json"
            suffix += 1
        }
        let backup = folder.appendingPathComponent(name)
        do {
            try data.write(to: backup, options: .withoutOverwriting)
            return .backedUp(backup)
        } catch {
            return .failed
        }
    }
}
