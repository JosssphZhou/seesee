import Foundation

/// 看板的列，也是列表视图左侧栏的分组。和数据层的五个状态一一对应，这里只管怎么摆、叫什么。
enum BoardColumn: String, CaseIterable, Identifiable {
    case inbox
    case toWatch
    case watching
    case watched
    case archived

    /// 看完满这么多天的条目，已看完列头给「归档 N 条」。
    static let archiveSuggestionDays = 30

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return "收件箱"
        case .toWatch: return "待看"
        case .watching: return "观看中"
        case .watched: return "已看完"
        case .archived: return "已归档"
        }
    }

    /// 看板从左往右按流程排。
    static func boardColumns(showsArchived: Bool) -> [BoardColumn] {
        showsArchived ? allCases : [.inbox, .toWatch, .watching, .watched]
    }

    /// 列表视图把正在看的放最上面，打开就能接着看；已看完分组同时放已归档。
    static let listSections: [BoardColumn] = [.watching, .inbox, .toWatch, .watched]

    /// 列表视图里这一条落在哪个分组。
    var listSection: BoardColumn {
        self == .archived ? .watched : self
    }
}

/// 按列分好的条目。列内顺序沿用传进来的顺序，由数据层定。
struct BoardColumnGroups: Equatable {
    private(set) var itemIDs: [BoardColumn: [UUID]] = [:]

    init<Item: Identifiable>(
        _ items: [Item],
        column: (Item) -> BoardColumn
    ) where Item.ID == UUID {
        for item in items {
            itemIDs[column(item), default: []].append(item.id)
        }
    }

    subscript(column: BoardColumn) -> [UUID] {
        itemIDs[column] ?? []
    }

    func count(_ column: BoardColumn) -> Int {
        self[column].count
    }

    /// 列表视图的分组：已看完分组接上已归档。
    func listSection(_ section: BoardColumn) -> [UUID] {
        section == .watched ? self[.watched] + self[.archived] : self[section]
    }
}

/// 卡片拖动时带的内容：前缀加条目编号，另外登记一个只有看板认得的类型，松手时不读内容就能认出是卡片。别处拖进来的文字不认。
enum BoardDragPayload {
    static let prefix = "seesee-board-item:"
    static let typeIdentifier = "ai.openmy.seesee.board-item"

    static func string(for id: UUID) -> String {
        prefix + id.uuidString
    }

    static func itemID(from string: String) -> UUID? {
        guard isCardText(string) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }

    /// 以前缀开头的文字或链接是看板卡片，不是要添加的链接。
    static func isCardText(_ string: String) -> Bool {
        string.hasPrefix(prefix)
    }

    static func provider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider(object: string(for: id) as NSString)
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    static func isCard(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains(typeIdentifier)
    }
}

extension WatchItem {
    /// 卡片第一行、面板顶栏和读屏共用的标题。标题为空（多半是拿到标题之前就下载失败）时显示链接，
    /// 来源名留在频道行；链接也为空才用来源名。
    var boardTitle: String {
        let primary = titleDisplay.primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        let link = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return link.isEmpty ? sourceName : link
    }

    /// 卡片频道行：作者为空时用来源名。
    var boardChannel: String {
        author.isEmpty ? sourceName : author
    }
}

/// 卡片的读屏内容：标签是 `boardTitle`，值是频道，有状态文字时接在后面。
enum BoardCardAccessibility {
    static func value(channel: String, status: BoardCardStatusText.Value?) -> String {
        guard let status else { return channel }
        return "\(channel)，\(status.text)"
    }
}

/// 卡片信息行右侧的状态文字。正常状态不显示，只有等待下载、下载中、预览、下载失败、观看进度才显示。
enum BoardCardStatusText {
    struct Value: Equatable {
        var text: String
        var isFailure = false
        /// 纯百分比（例如「43%」）用等宽数字字体。
        var isPercentOnly = false
    }

    /// 数据层排队时写进 progressLabel 的词，界面上统一说「等待下载」。
    static let waitingForSlotLabel = "等待下载槽位"

    static func value(
        isFailed: Bool,
        downloadRowText: String,
        watchedFraction: Double?
    ) -> Value? {
        if isFailed {
            return Value(text: "下载失败", isFailure: true)
        }
        let row = downloadRowText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !row.isEmpty {
            let text = row == waitingForSlotLabel ? "等待下载" : row
            return Value(text: text, isPercentOnly: text.hasSuffix("%") && Int(text.dropLast()) != nil)
        }
        if let watchedFraction, watchedFraction > 0, watchedFraction.isFinite {
            let percent = min(99, max(1, Int((watchedFraction * 100).rounded())))
            return Value(text: "观看进度 \(percent)%")
        }
        return nil
    }
}

extension BoardColumn {
    /// 数据层的五个状态和看板五列一一对应。
    init(_ status: WatchStatus) {
        switch status {
        case .inbox: self = .inbox
        case .toWatch: self = .toWatch
        case .watching: self = .watching
        case .watched: self = .watched
        case .archived: self = .archived
        }
    }

    var status: WatchStatus {
        switch self {
        case .inbox: return .inbox
        case .toWatch: return .toWatch
        case .watching: return .watching
        case .watched: return .watched
        case .archived: return .archived
        }
    }
}

extension BoardColumn {
    /// 已看完列头「归档 N 条」要挪的条目：已看完、看完满 30 天。不自动归档，只给入口。
    static func archiveCandidates(_ items: [WatchItem], now: Date = Date()) -> [UUID] {
        items
            .filter { $0.isWatched(forAtLeastDays: archiveSuggestionDays, now: now) }
            .map(\.id)
    }
}
