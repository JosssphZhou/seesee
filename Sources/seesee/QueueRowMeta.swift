import Foundation

enum QueueRowMeta {
    enum SourceMark: Equatable, Hashable {
        case youtube
        case bilibili
        case xiaohongshu
        case x
        case unknown
    }

    static func sourceMark(for sourceName: String) -> SourceMark {
        switch sourceName {
        case "YouTube":
            return .youtube
        case "哔哩哔哩":
            return .bilibili
        case "小红书":
            return .xiaohongshu
        case "X":
            return .x
        default:
            return .unknown
        }
    }

    /// 正常态沉默：就绪是常态，不占用文字；只有排队、下载、失败这些异常态才说话。
    static func statusText(state: DownloadState, progressLabel: String) -> String {
        switch state {
        case .queued, .downloading, .failed:
            return progressLabel
        case .ready:
            return ""
        }
    }

    /// 作者名已单独显示时，标题里的「作者 - 」前缀是重复信息，显示层剥掉；改名编辑仍用原始标题。
    static func displayTitle(title: String, author: String) -> String {
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)
        guard !trimmedAuthor.isEmpty else { return title }
        for separator in [" - ", " – ", " \u{2014} "] {
            let prefix = trimmedAuthor + separator
            if title.hasPrefix(prefix) {
                let rest = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return title
    }

    /// 失败原因人话化：一级信息一句话，原始报错收进「详情」展开区。
    static func failureSummary(from raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "未知的下载错误" }
        let lower = raw.lowercased()
        if lower.contains("ssl") || lower.contains("unable to download webpage")
            || lower.contains("timed out") || lower.contains("connection") || lower.contains("network") {
            return "网络连接中断，无法获取视频页面"
        }
        if lower.contains("404") || lower.contains("not found") || lower.contains("unavailable") {
            return "视频不存在或已下架"
        }
        if lower.contains("private") || lower.contains("login") || lower.contains("sign in") || lower.contains("cookies") {
            return "视频需要登录或没有访问权限"
        }
        if lower.contains("geo") || lower.contains("country") || lower.contains("region") {
            return "视频在当前地区不可用"
        }
        if lower.contains("no space") || lower.contains("disk full") {
            return "磁盘空间不足"
        }
        return "下载工具报错，展开详情查看原文"
    }

    /// 小于此位移仍当单击，避免微抖被认成排序。
    static let reorderDragThreshold: CGFloat = 12

    /// 本机文件还在才给出访达定位路径；缺文件或空路径不显示该菜单项。
    static func localFileToReveal(path: String?, exists: (String) -> Bool) -> String? {
        guard let path, !path.isEmpty, exists(path) else { return nil }
        return path
    }

    enum ContextMenuItem: Equatable, Hashable {
        case toggleWatched
        case rename
        case retryDownload
        case openOriginal
        case revealInFinder
        case divider
        case delete
    }

    enum TitleEditEndReason: Equatable {
        case submit
        case escape
        case focusLost
    }

    enum TitleEditCommit: Equatable {
        case save(String)
        case discard
    }

    static func contextMenuItems(
        state: DownloadState,
        canRevealLocalFile: Bool
    ) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = [.toggleWatched, .rename]
        if state == .failed {
            items.append(.retryDownload)
        }
        items.append(.openOriginal)
        if canRevealLocalFile {
            items.append(.revealInFinder)
        }
        items.append(contentsOf: [.divider, .delete])
        return items
    }

    static func visibleTitle(for item: ContextMenuItem, isWatched: Bool) -> String {
        switch item {
        case .toggleWatched:
            return isWatched ? "移回队列" : "标记已看"
        case .rename:
            return "重命名"
        case .retryDownload:
            return "重试下载"
        case .openOriginal:
            return "打开原网页"
        case .revealInFinder:
            return "在访达中显示"
        case .divider:
            return ""
        case .delete:
            return "删除"
        }
    }

    struct TitleClickState: Equatable {
        var selectedAtPairStart: Bool?
    }

    enum TitleClickAction: Equatable {
        case beginEditing
        case select
    }

    /// 第二击必须用第一击时的选中状态。两击之间 SwiftUI 重绘把 isSelected 改成 true 不得进编辑。
    static func handleTitleClick(
        state: TitleClickState,
        isSelected: Bool,
        clickCount: Int,
        continuesPair: Bool
    ) -> (TitleClickState, TitleClickAction) {
        let isContinuation = (clickCount >= 2 || continuesPair) && state.selectedAtPairStart != nil
        if isContinuation {
            let selectedAtStart = state.selectedAtPairStart ?? false
            return (TitleClickState(selectedAtPairStart: nil), selectedAtStart ? .beginEditing : .select)
        }
        return (TitleClickState(selectedAtPairStart: isSelected), .select)
    }

    static func titleEditCommit(reason: TitleEditEndReason, draft: String) -> TitleEditCommit {
        switch reason {
        case .escape:
            return .discard
        case .submit, .focusLost:
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .discard : .save(trimmed)
        }
    }
}
