import Foundation

enum SubtitleTrackRank {
    /// 数值越小越优先：双语 `.zh` > 英轨 > YouTube 中文机翻 > 其他。
    static func value(for url: URL) -> Int {
        value(forStem: url.deletingPathExtension().lastPathComponent)
    }

    static func value(forStem raw: String) -> Int {
        let name = raw.lowercased()
        if name.hasSuffix(".zh") { return 0 }
        if name.hasSuffix(".en") { return 10 }
        if name.hasSuffix(".en-orig") { return 11 }
        if name.range(of: #"\.en[-_]"#, options: .regularExpression) != nil { return 12 }
        if name.hasSuffix(".zh-hans") || name.hasSuffix(".zh-cn") { return 20 }
        if name.hasSuffix(".zh-hant") || name.hasSuffix(".zh-tw") || name.hasSuffix(".zh-hk") { return 21 }
        if name.range(of: #"\.zh[-_]"#, options: .regularExpression) != nil { return 22 }
        return 100
    }
}
