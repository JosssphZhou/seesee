import Foundation

// 视图切换和看板分列的检查：在没有看板的 main 上缺 LibraryViewMode、BoardColumn，编译即失败。
// 编译：swiftc Sources/seesee/{WatchItem,ChapterMetadata,LibraryViewMode,BoardColumns}.swift
//       加上数据层的 WatchStatus 所在文件，再加本文件。

nonisolated(unsafe) var failures: [String] = []

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

func item(
    watchedDaysAgo: Double? = nil,
    position: Double? = nil,
    state: DownloadState = .ready
) -> WatchItem {
    WatchItem(
        id: UUID(),
        urlString: "https://example.com/video",
        title: "示例",
        author: "频道",
        duration: 600,
        addedAt: Date(),
        watchedAt: watchedDaysAgo.map { Date().addingTimeInterval(-$0 * 24 * 60 * 60) },
        state: state,
        progress: 1,
        progressLabel: "",
        localFilePath: nil,
        errorMessage: nil,
        playbackPosition: position,
        chapters: nil,
        thumbnailFilePath: nil,
        subtitleFilePath: nil
    )
}

@main
struct BoardLayoutCheck {
    static func main() {
        // 1. 视图模式：默认列表视图，切到看板后记住，⌘1 和 ⌘2 对应列表和看板。
        let suiteName = "board-layout-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        expect(LibraryViewMode.stored(in: defaults) == .list, "没存过时默认应是列表视图")
        LibraryViewMode.store(.board, in: defaults)
        expect(LibraryViewMode.stored(in: defaults) == .board, "切到看板后应记住看板视图")
        defaults.set("unknown", forKey: LibraryViewMode.defaultsKey)
        expect(LibraryViewMode.stored(in: defaults) == .list, "不认识的值应回到列表视图")
        defaults.removePersistentDomain(forName: suiteName)
        expect(LibraryViewMode.list.shortcutKey == "1" && LibraryViewMode.board.shortcutKey == "2", "⌘1 列表、⌘2 看板")

        // 2. 列：四列固定顺序，已归档是可选的第五列。
        expect(
            BoardColumn.boardColumns(showsArchived: false) == [.inbox, .toWatch, .watching, .watched],
            "关掉已归档列时应是收件箱、待看、观看中、已看完四列"
        )
        expect(
            BoardColumn.boardColumns(showsArchived: true) == [.inbox, .toWatch, .watching, .watched, .archived],
            "打开已归档列时应在最后加已归档"
        )
        expect(BoardColumn.boardColumns(showsArchived: false).map(\.title) == ["收件箱", "待看", "观看中", "已看完"], "列名")

        // 3. 列表视图分组：观看中、收件箱、待看、已看完，已归档并进已看完。
        expect(BoardColumn.listSections == [.watching, .inbox, .toWatch, .watched], "列表分组顺序")
        expect(BoardColumn.archived.listSection == .watched, "已归档在列表里并进已看完分组")

        // 4. 五个状态和五列一一对应。
        for status in WatchStatus.allCases {
            expect(BoardColumn(status).status == status, "状态 \(status.rawValue) 应和列来回对得上")
        }

        // 5. 分列：按条目的状态放进对应的列，组内保持传进来的顺序。
        let unwatched = item()
        let watching = item(position: 120)
        let watchedRecently = item(watchedDaysAgo: 2)
        let watchedLongAgo = item(watchedDaysAgo: 40)
        let all = [unwatched, watching, watchedRecently, watchedLongAgo]
        let groups = BoardColumnGroups(all) { BoardColumn($0.status) }
        expect(groups[.watching] == [watching.id], "有观看进度的进观看中")
        expect(groups[.watched] == [watchedRecently.id, watchedLongAgo.id], "看完的进已看完，顺序不变")
        expect(groups.count(.toWatch) + groups.count(.inbox) == 1, "没看过的进待看或收件箱")
        let archivedGroups = BoardColumnGroups(all) { $0.id == watchedLongAgo.id ? .archived : BoardColumn($0.status) }
        expect(archivedGroups.listSection(.watched) == [watchedRecently.id, watchedLongAgo.id], "列表的已看完分组接上已归档")
        expect(archivedGroups[.watched] == [watchedRecently.id], "看板的已看完列不含已归档")

        // 6. 已看完满 30 天才给「归档 N 条」。
        expect(BoardColumn.archiveCandidates(all) == [watchedLongAgo.id], "只有看完满 30 天的条目算进归档入口")

        // 7. 卡片状态文字：正常不显示，异常和进行中才显示。
        expect(BoardCardStatusText.value(isFailed: false, downloadRowText: "", watchedFraction: nil) == nil, "已就绪不显示状态文字")
        expect(BoardCardStatusText.value(isFailed: true, downloadRowText: "重试 3 次后失败", watchedFraction: nil)?.text == "下载失败", "失败统一说下载失败")
        expect(BoardCardStatusText.value(isFailed: true, downloadRowText: "", watchedFraction: nil)?.isFailure == true, "失败用警示色")
        expect(BoardCardStatusText.value(isFailed: false, downloadRowText: "等待下载槽位", watchedFraction: nil)?.text == "等待下载", "排队说等待下载")
        let percent = BoardCardStatusText.value(isFailed: false, downloadRowText: "43%", watchedFraction: nil)
        expect(percent?.text == "43%" && percent?.isPercentOnly == true, "下载百分比用等宽数字")
        expect(BoardCardStatusText.value(isFailed: false, downloadRowText: "预览 · 61%", watchedFraction: nil)?.isPercentOnly == false, "预览百分比带字")
        expect(BoardCardStatusText.value(isFailed: false, downloadRowText: "", watchedFraction: 0.4)?.text == "观看进度 40%", "观看进度")

        // 8. 播放器面板宽度：有上下限，左边至少留一列看板。
        expect(BoardPlayerPanelMetrics.clampedWidth(100, windowWidth: 1320) == BoardPlayerPanelMetrics.minimumWidth, "面板不窄于下限")
        expect(BoardPlayerPanelMetrics.clampedWidth(5000, windowWidth: 1320) == 1320 - BoardPlayerPanelMetrics.minimumBoardWidth, "面板不挤掉看板")
        expect(BoardPlayerPanelMetrics.clampedWidth(.nan, windowWidth: 1320) == BoardPlayerPanelMetrics.defaultWidth, "读到坏值用默认宽度")

        // 9. 卡片标题和读屏：标题为空时显示链接，来源名留在频道行；值是频道加状态文字。
        var untitled = item(state: .failed)
        untitled.title = ""
        untitled.author = ""
        untitled.urlString = "https://www.youtube.com/watch?v=x"
        expect(untitled.boardTitle == "https://www.youtube.com/watch?v=x", "标题为空显示链接")
        expect(untitled.boardChannel == "YouTube", "作者为空频道用来源名")
        untitled.urlString = ""
        expect(untitled.boardTitle == untitled.sourceName, "链接也为空才用来源名")
        expect(item().boardTitle == "示例" && item().boardChannel == "频道", "有标题和作者时照常显示")
        let failedStatus = BoardCardStatusText.value(isFailed: true, downloadRowText: "", watchedFraction: nil)
        expect(BoardCardAccessibility.value(channel: "频道乙", status: failedStatus) == "频道乙，下载失败", "读屏值带状态文字")
        expect(BoardCardAccessibility.value(channel: "频道乙", status: nil) == "频道乙", "没有状态文字只读频道")

        // 10. 拖动内容：卡片带看板专用类型，浏览器拖来的链接和文字认不成卡片。
        let cardID = UUID()
        let cardProvider = BoardDragPayload.provider(for: cardID)
        expect(BoardDragPayload.isCard(cardProvider), "卡片的拖动内容带看板专用类型")
        expect(!BoardDragPayload.isCard(NSItemProvider(object: URL(string: "https://www.youtube.com/watch?v=x")! as NSURL)), "链接不算卡片")
        expect(!BoardDragPayload.isCard(NSItemProvider(object: "https://example.com" as NSString)), "文字不算卡片")
        expect(BoardDragPayload.isCardText(BoardDragPayload.string(for: cardID)), "卡片文字以前缀开头")
        expect(!BoardDragPayload.isCardText("https://example.com/seesee-board-item:x"), "普通链接不当成卡片")
        expect(BoardDragPayload.itemID(from: BoardDragPayload.string(for: cardID)) == cardID, "卡片文字能读回编号")

        if failures.isEmpty {
            print("board_layout_check: 全部通过")
        } else {
            failures.forEach { print("失败：\($0)") }
            exit(1)
        }
    }
}
