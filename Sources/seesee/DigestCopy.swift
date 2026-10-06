import Foundation

enum DigestCopy {
    static let saveFailed = "这次没存上，请再试一次"
    static let fileCorrupt = "这份记录损坏了，没有覆盖原文件"
    static let emptyTitle = "暂无字幕"
    static let emptyLoadingDetail = "字幕仍在加载，或文件无法解析。"
    static let emptyUnavailableDetail = "当前视频没有可用字幕。"

    static func emptyDetail(hasSubtitleSource: Bool) -> String {
        hasSubtitleSource ? emptyLoadingDetail : emptyUnavailableDetail
    }

    static func showsBook(cueCount: Int) -> Bool {
        cueCount > 0
    }

    static func showsDigestActions(cueCount: Int) -> Bool {
        cueCount > 0
    }
}
