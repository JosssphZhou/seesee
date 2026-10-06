import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: QueueStore
    @EnvironmentObject private var inbox: URLInbox
    @State private var urlText = ""
    @State private var isDropTarget = false
    @State private var itemToDelete: WatchItem?
    @State private var detailSelection: UUID?
    @State private var detailSelectionTask: Task<Void, Never>?
    @State private var knownItemIDs: Set<UUID> = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var queueRowFrames: [UUID: CGRect] = [:]
    @State private var windowWidth: CGFloat = 1320
    @State private var urlBarFrame: CGRect = .zero
    @State private var pendingRenameID: UUID?
    @AppStorage("sidebarWatchedCollapsed") private var watchedCollapsed = false
    @AppStorage("sidebarSubscriptionsCollapsed") private var subscriptionsCollapsed = false
    /// 收件箱、待看、观看中三个分组的折叠状态，逗号分隔；已看完和订阅沿用原来的两个键。
    @AppStorage("sidebarCollapsedSections") private var collapsedListSections = ""
    @AppStorage(LibraryViewMode.defaultsKey) private var viewMode: LibraryViewMode = .list
    @AppStorage(BoardPlayerPanelMetrics.widthDefaultsKey) private var boardPanelWidth = BoardPlayerPanelMetrics.defaultWidth
    @AppStorage(BoardArchivedColumnSetting.defaultsKey) private var showsArchivedColumn = false
    @ObservedObject private var boardPanel = BoardPlayerPanelState.shared
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        Group {
            if viewMode == .board {
                boardLayout
            } else {
                listLayout
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .seeseeSidebarToggle)) { notification in
            // 菜单「显示或隐藏左侧栏」（⌃⌘S）与离屏检查共用：带 collapsed 就设成指定态，否则切换。
            let target: NavigationSplitViewVisibility
            if let collapsed = notification.userInfo?["collapsed"] as? Bool {
                target = collapsed ? .detailOnly : .all
            } else {
                target = columnVisibility == .detailOnly ? .all : .detailOnly
            }
            withAnimation(.easeInOut(duration: 0.22)) {
                columnVisibility = target
            }
        }
        // 窗口最小尺寸只写在 NSWindow.minSize。若给 SplitView 设死 minWidth，
        // 侧栏滑出时 fittingSize 会变成窗口宽加栏宽，内容按比例撑出窗口。
        .coordinateSpace(name: "seesee-window")
        .onPreferenceChange(URLBarFramePreferenceKey.self) { urlBarFrame = $0 }
        .background {
            ZStack {
                WindowStyleConfigurator(title: store.selectedItem?.titleDisplay.primary ?? "seesee", layoutKey: viewMode.rawValue)
                    .frame(width: 0, height: 0)

                WindowWidthReader { width in
                    guard abs(windowWidth - width) > 0.5 else { return }
                    windowWidth = width
                }
                .frame(width: 0, height: 0)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let warning = store.queueWriteWarning {
                    QueueBackupFailureBanner(message: warning)
                        .padding(.top, 12)
                }
                if store.isMediaFolderDisconnected {
                    MediaFolderDisconnectedBanner(path: DigestSettingsCopy.displayPath(store.mediaFolder))
                        .padding(.top, store.queueWriteWarning == nil ? 12 : 0)
                }
                if let notice = store.intakeNotice {
                    IntakeToast(notice: notice, dismiss: store.dismissIntakeNotice)
                        .padding(.top, store.isMediaFolderDisconnected || store.queueWriteWarning != nil ? 0 : 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .zIndex(20)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: store.intakeNotice?.id)
        .onAppear {
            isURLFieldFocused = false
            if detailSelection == nil { detailSelection = store.selection }
            knownItemIDs = Set(store.items.map(\.id))
            consumePendingURLs()
            consumePendingClipboardValues()
        }
        .onReceive(NotificationCenter.default.publisher(for: .seeseeTextFocusShouldResign)) { _ in
            isURLFieldFocused = false
        }
        .onChange(of: isURLFieldFocused) { focused in
            let controller = PlaybackWindowFocusController.attached(to: NSApp.keyWindow)
            if focused, controller?.allowTextFocus == false {
                isURLFieldFocused = false
                return
            }
            controller?.setSwiftUITextFieldFocused(focused)
        }
        .onDisappear { detailSelectionTask?.cancel() }
        .onChange(of: store.selection) { selectedID in
            updateDetailAfterSelectionPaints(selectedID)
        }
        .onChange(of: inbox.urls) { urls in
            urls.forEach(store.accept)
            inbox.clear()
        }
        .onChange(of: inbox.clipboardValues) { values in
            values.forEach { store.accept(rawValue: $0) }
            inbox.clearClipboard()
        }
        .onChange(of: store.items) { items in
            DownloadProgressMemory.observe(items, isPreviewPlayable: store.isPreviewPlayable)
        }
        .alert(store.queueWriteWarning == nil ? "添加链接失败" : "无法保存改动", isPresented: Binding(
            get: { store.lastIntakeError != nil },
            set: { if !$0 { store.lastIntakeError = nil } }
        )) {
            Button("好", role: .cancel) { store.lastIntakeError = nil }
        } message: {
            Text(store.lastIntakeError ?? "未知错误")
        }
        .confirmationDialog(
            "删除这个视频？",
            isPresented: Binding(get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除视频和本地文件", role: .destructive) {
                if let itemToDelete { store.remove(itemToDelete.id) }
                itemToDelete = nil
            }
            Button("取消", role: .cancel) { itemToDelete = nil }
        }
        .confirmationDialog(
            "加入订阅？",
            isPresented: Binding(
                get: { store.pendingSubscriptionURL != nil },
                set: { if !$0 { store.cancelPendingSubscription() } }
            ),
            titleVisibility: .visible
        ) {
            Button("加入订阅") { store.confirmPendingSubscription() }
            Button("取消", role: .cancel) { store.cancelPendingSubscription() }
        } message: {
            let name = store.pendingSubscriptionURL.map(ChannelLink.displayTitle(for:)) ?? "这个频道"
            Text("\(name) 是频道或播放列表。加入后，有新视频会自动入队下载。")
        }
    }

    /// 列表视图：左侧栏按状态分组，右边是播放器和字幕栏。
    private var listLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 272, ideal: 312, max: 360)
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("seesee-window"))
                        .onEnded(handleWindowTap)
                )
        } detail: {
            detail
                .simultaneousGesture(
                    TapGesture().onEnded(dismissURLFieldFocus)
                )
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// 看板视图：顶栏下面按状态分列，点卡片从右边滑出播放器，看板留在左边。
    private var boardLayout: some View {
        let itemsByID = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = BoardColumnGroups(store.queueItems + store.archivedItems, column: boardColumn(for:))
        let columns = BoardColumn.boardColumns(showsArchived: showsArchivedColumn)
        let panelItem = boardPanel.isPresented ? store.selection.flatMap { itemsByID[$0] } : nil

        return VStack(spacing: 0) {
            BoardTopBar(itemCount: store.items.count, mode: $viewMode) {
                DropAndAddBar(
                    urlText: $urlText,
                    isDropTarget: $isDropTarget,
                    isURLFieldFocused: $isURLFieldFocused,
                    submit: submitURL,
                    receiveProviders: receiveProviders
                )
            }
            Divider()
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: BoardMetrics.columnSpacing) {
                        ForEach(columns) { column in
                            BoardColumnView(
                                column: column,
                                itemIDs: groups[column],
                                onDropItem: { moveBoardItem($0, to: column) }
                            ) {
                                boardColumnTrailing(column, items: groups[column].compactMap { itemsByID[$0] })
                            } card: { id in
                                if let item = itemsByID[id] {
                                    boardCard(item, column: column, columns: columns)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, BoardMetrics.boardHorizontalPadding)
                    .padding(.top, BoardMetrics.boardTopPadding)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .simultaneousGesture(TapGesture().onEnded(dismissURLFieldFocus))

                if let panelItem {
                    BoardPlayerPanel(width: $boardPanelWidth, windowWidth: windowWidth) {
                        VideoDetail(
                            item: panelItem,
                            sidebarCollapsed: true,
                            windowWidth: windowWidth,
                            collapseSidebar: {},
                            layout: .stacked,
                            collapsePanel: { _ = boardPanel.collapse() }
                        )
                        .id(panelItem.id)
                    }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
                }
            }
        }
        .background(OpenMyChrome.canvas)
        .ignoresSafeArea(.container, edges: .top)
        // 不设标题时 SwiftUI 会把应用名画进工具栏，露在顶栏标题左边。
        .navigationTitle("")
        // 列表视图的分栏自带工具栏（侧栏钮），窗口的标题栏高度和透明样式都跟着它。
        // 看板没有分栏，留一个不可见的工具栏项，标题栏才和列表视图一样，切换时顶栏不跳。
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private func boardColumn(for item: WatchItem) -> BoardColumn {
        BoardColumn(item.status)
    }

    /// 拖到别的列就是手动改状态，走数据层的挪动方法，立刻落盘。拖回原来那列不算。
    @discardableResult
    private func moveBoardItem(_ id: UUID, to column: BoardColumn) -> Bool {
        guard let item = store.items.first(where: { $0.id == id }),
              boardColumn(for: item) != column else { return false }
        withAnimation(.easeInOut(duration: 0.18)) {
            _ = store.moveItems([id], to: column.status)
        }
        return true
    }

    @ViewBuilder
    private func boardColumnTrailing(_ column: BoardColumn, items: [WatchItem]) -> some View {
        switch column {
        case .inbox:
            BoardColumnHeaderButton(kind: .add) {
                isURLFieldFocused = true
            }
        case .watched:
            let candidates = BoardColumn.archiveCandidates(items)
            if !candidates.isEmpty {
                BoardColumnHeaderButton(kind: .archive(count: candidates.count)) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        _ = store.moveItems(candidates, to: .archived)
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private func boardCard(_ item: WatchItem, column: BoardColumn, columns: [BoardColumn]) -> some View {
        BoardCard(
            item: item,
            column: column,
            isSelected: boardPanel.isPresented && store.selection == item.id,
            isPreviewPlayable: store.isPreviewPlayable(item.id),
            open: { openBoardItem(item.id) },
            moveTo: { moveBoardItem(item.id, to: $0) },
            availableColumns: columns
        )
        .equatable()
        .id(item.id)
        .contextMenu {
            queueRowContextMenu(item, includesRename: false)
        }
    }

    private func openBoardItem(_ id: UUID) {
        dismissURLFieldFocus()
        store.selection = id
        store.rescanLocalSubtitle(for: id)
        guard !boardPanel.isPresented else { return }
        withAnimation(BoardPlayerPanelState.animation) {
            boardPanel.isPresented = true
        }
    }

    private var sidebar: some View {
        SidebarQueueChrome {
            DropAndAddBar(
                urlText: $urlText,
                isDropTarget: $isDropTarget,
                isURLFieldFocused: $isURLFieldFocused,
                submit: submitURL,
                receiveProviders: receiveProviders
            )
            // 红绿灯在左、系统侧栏钮在右。添加栏停在标题栏正中，避开两侧控件。
            .padding(.leading, 82)
            .padding(.trailing, 54)
        } content: {
            queueList
        }
    }

    /// 列表视图的分组：观看中、收件箱、待看、已看完（含已归档）。组内顺序沿用数据层给的顺序。
    private var listSectionGroups: BoardColumnGroups {
        BoardColumnGroups(store.queueItems + store.archivedItems) { boardColumn(for: $0).listSection }
    }

    @ViewBuilder
    private var queueList: some View {
        let itemsByID = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = listSectionGroups
        let sections = BoardColumn.listSections.filter { !groups[$0].isEmpty }
        let subscriptions = store.channelWatch.subscriptions

        if sections.isEmpty && subscriptions.isEmpty {
            SidebarEmptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    SidebarQueueLayout.ScrollStack {
                        LazyVStack(alignment: .leading, spacing: SidebarQueueLayout.rowSpacing, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                let ids = groups[section]
                                Section {
                                    if !isListSectionCollapsed(section) {
                                        ForEach(ids, id: \.self) { id in
                                            if let item = itemsByID[id] {
                                                sidebarRow(item)
                                                    .background {
                                                        GeometryReader { geometry in
                                                            Color.clear.preference(
                                                                key: QueueRowFramePreferenceKey.self,
                                                                value: [item.id: geometry.frame(in: .named("queue-list"))]
                                                            )
                                                        }
                                                    }
                                                    .simultaneousGesture(
                                                        DragGesture(
                                                            minimumDistance: QueueRowMeta.reorderDragThreshold,
                                                            coordinateSpace: .named("queue-list")
                                                        )
                                                        .onChanged { updateQueueDrag(item.id, within: ids, at: $0.location) }
                                                    )
                                            }
                                        }
                                    }
                                } header: {
                                    SidebarSectionHeader(
                                        title: section.title,
                                        count: ids.count,
                                        isCollapsed: isListSectionCollapsed(section)
                                    ) {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            toggleListSection(section)
                                        }
                                    }
                                    .padding(.top, section == sections.first ? SidebarQueueLayout.listTopPadding : 8)
                                }
                            }

                            if !subscriptions.isEmpty {
                                Section {
                                    if !subscriptionsCollapsed {
                                        ForEach(subscriptions) { subscription in
                                            SubscriptionRow(
                                                subscription: subscription,
                                                onDelete: { store.removeSubscription(subscription.id) }
                                            )
                                        }
                                    }
                                } header: {
                                    SidebarSectionHeader(
                                        title: "订阅",
                                        count: subscriptions.count,
                                        isCollapsed: subscriptionsCollapsed
                                    ) {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            subscriptionsCollapsed.toggle()
                                        }
                                    }
                                    .padding(.top, sections.isEmpty ? SidebarQueueLayout.listTopPadding : 8)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .scrollIndicators(.hidden)
                .clipped()
                .coordinateSpace(name: "queue-list")
                .onPreferenceChange(QueueRowFramePreferenceKey.self) { queueRowFrames = $0 }
                .onChange(of: store.items.map(\.id)) { itemIDs in
                    let addedID = itemIDs.first { !knownItemIDs.contains($0) }
                    knownItemIDs = Set(itemIDs)
                    guard let addedID else { return }
                    // 新加的条目所在分组收着时先展开，否则滚过去也看不到。
                    if let added = store.items.first(where: { $0.id == addedID }) {
                        let section = boardColumn(for: added).listSection
                        if isListSectionCollapsed(section) { toggleListSection(section) }
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(addedID, anchor: .top)
                    }
                }
                .onAppear {
                    // A persisted selection can be far down the queue. The
                    // list itself should nevertheless start at its real top
                    // after every launch, with the normal eight-point inset
                    // above the newest item.
                    DispatchQueue.main.async {
                        proxy.scrollTo(SidebarQueueLayout.queueTopAnchorID, anchor: .top)
                    }
                }
            }
        }
    }

    private func sidebarRow(_ item: WatchItem, includesListTopGutter: Bool = false) -> some View {
        QueueRow(
            item: item,
            isSelected: store.selection == item.id,
            isPreviewPlayable: store.isPreviewPlayable(item.id),
            includesListTopGutter: includesListTopGutter,
            select: {
                store.selection = item.id
                detailSelection = item.id
                store.rescanLocalSubtitle(for: item.id)
            },
            rename: { store.rename(item.id, to: $0) },
            pendingRename: pendingRenameID == item.id,
            consumePendingRename: {
                if pendingRenameID == item.id {
                    pendingRenameID = nil
                }
            }
        )
        .equatable()
        .id(item.id)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            queueRowContextMenu(item)
        }
    }

    /// 看板卡片上没有可就地编辑的标题，菜单不放「重命名」；改名在列表视图里做。
    @ViewBuilder
    private func queueRowContextMenu(_ item: WatchItem, includesRename: Bool = true) -> some View {
        let canReveal = QueueRowMeta.localFileToReveal(
            path: item.localFilePath,
            exists: { FileManager.default.fileExists(atPath: $0) }
        ) != nil
        let items = QueueRowMeta.contextMenuItems(
            state: item.state,
            canRevealLocalFile: canReveal
        ).filter { includesRename || $0 != .rename }
        ForEach(items, id: \.self) { menuItem in
            queueRowContextMenuEntry(menuItem, for: item)
        }
    }

    @ViewBuilder
    private func queueRowContextMenuEntry(
        _ menuItem: QueueRowMeta.ContextMenuItem,
        for item: WatchItem
    ) -> some View {
        switch menuItem {
        case .toggleWatched:
            Button(QueueRowMeta.visibleTitle(for: .toggleWatched, isWatched: item.isWatched)) {
                store.toggleWatched(item.id)
            }
        case .rename:
            Button(QueueRowMeta.visibleTitle(for: .rename, isWatched: item.isWatched)) {
                requestRename(item)
            }
        case .retryDownload:
            Button(QueueRowMeta.visibleTitle(for: .retryDownload, isWatched: item.isWatched)) {
                store.startDownload(for: item.id)
            }
        case .openOriginal:
            Button(QueueRowMeta.visibleTitle(for: .openOriginal, isWatched: item.isWatched)) {
                store.openOriginal(item.id)
            }
        case .revealInFinder:
            Button(QueueRowMeta.visibleTitle(for: .revealInFinder, isWatched: item.isWatched)) {
                store.revealLocalFile(item.id)
            }
        case .divider:
            Divider()
        case .delete:
            Button(QueueRowMeta.visibleTitle(for: .delete, isWatched: item.isWatched), role: .destructive) {
                itemToDelete = item
            }
        }
    }

    private func requestRename(_ item: WatchItem) {
        if store.selection != item.id {
            store.selection = item.id
            detailSelection = item.id
        }
        pendingRenameID = item.id
    }

    private func isListSectionCollapsed(_ section: BoardColumn) -> Bool {
        if section == .watched { return watchedCollapsed }
        return collapsedListSections.split(separator: ",").contains(Substring(section.rawValue))
    }

    private func toggleListSection(_ section: BoardColumn) {
        if section == .watched {
            watchedCollapsed.toggle()
            return
        }
        var collapsed = Set(collapsedListSections.split(separator: ",").map(String.init))
        if collapsed.contains(section.rawValue) {
            collapsed.remove(section.rawValue)
        } else {
            collapsed.insert(section.rawValue)
        }
        collapsedListSections = collapsed.sorted().joined(separator: ",")
    }

    /// 列表里拖动排序只在同一个分组里换位置。
    private func updateQueueDrag(_ draggedID: UUID, within sectionIDs: [UUID], at location: CGPoint) {
        let sameSection = Set(sectionIDs)
        guard let target = queueRowFrames
            .filter({ $0.key != draggedID && sameSection.contains($0.key) && $0.value.contains(location) })
            .min(by: { abs($0.value.midY - location.y) < abs($1.value.midY - location.y) }) else { return }
        let insertAfter = location.y >= target.value.midY
        withAnimation(.easeInOut(duration: 0.15)) {
            store.reorderQueueItem(draggedID, relativeTo: target.key, insertAfter: insertAfter)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let detailSelection,
           let item = store.items.first(where: { $0.id == detailSelection }) {
            VideoDetail(
                item: item,
                sidebarCollapsed: columnVisibility == .detailOnly,
                windowWidth: windowWidth,
                collapseSidebar: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        columnVisibility = .detailOnly
                    }
                }
            )
                .id(item.id)
        } else {
            EmptyLibraryView(isDropTarget: $isDropTarget, receiveProviders: receiveProviders)
        }
    }

    private func updateDetailAfterSelectionPaints(_ selectedID: UUID?) {
        detailSelectionTask?.cancel()
        detailSelectionTask = Task {
            await Task.yield()
            guard !Task.isCancelled, store.selection == selectedID else { return }
            detailSelection = selectedID
        }
    }

    private func submitURL() {
        let value = urlText
        urlText = ""
        store.accept(rawValue: value)
    }

    private func consumePendingURLs() {
        guard !inbox.urls.isEmpty else { return }
        inbox.urls.forEach(store.accept)
        inbox.clear()
    }

    private func consumePendingClipboardValues() {
        guard !inbox.clipboardValues.isEmpty else { return }
        inbox.clipboardValues.forEach { store.accept(rawValue: $0) }
        inbox.clearClipboard()
    }

    private func receiveProviders(_ providers: [NSItemProvider]) -> Bool {
        // 看板卡片拖到添加链接框上松手：不是链接，直接忽略，不提示。
        guard !BoardDragPayload.isCardDrop(providers) else { return false }
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSURL.self) {
                accepted = true
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let url = object as? URL, !BoardDragPayload.isCardText(url.absoluteString) else { return }
                    DispatchQueue.main.async { store.accept(url) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String, !BoardDragPayload.isCardText(text) else { return }
                    DispatchQueue.main.async { store.accept(rawValue: text) }
                }
            }
        }
        return accepted
    }

    private func handleWindowTap(_ tap: SpatialTapGesture.Value) {
        guard !urlBarFrame.contains(tap.location) else { return }
        dismissURLFieldFocus()
    }

    private func dismissURLFieldFocus() {
        guard isURLFieldFocused else { return }
        isURLFieldFocused = false
        PlaybackWindowFocusController.resign(in: NSApp.keyWindow)
    }
}

private struct QueueRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct URLBarFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct IntakeToast: View {
    let notice: QueueStore.IntakeNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.systemImage)
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(OpenMyChrome.ink)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.leading, 13)
        .padding(.trailing, 9)
        .watchGlass(.regular, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous))
        .frame(maxWidth: 430)
    }
}

private struct QueueRow: View, Equatable {
    let item: WatchItem
    let isSelected: Bool
    let isPreviewPlayable: Bool
    let includesListTopGutter: Bool
    let select: () -> Void
    let rename: (String) -> Void
    let pendingRename: Bool
    let consumePendingRename: () -> Void
    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @State private var isHovering = false
    @State private var lastSelectClickAt: Date?
    @State private var titleClickState = QueueRowMeta.TitleClickState()
    @FocusState private var isTitleFocused: Bool

    static func == (lhs: QueueRow, rhs: QueueRow) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelected == rhs.isSelected
            && lhs.isPreviewPlayable == rhs.isPreviewPlayable
            && lhs.includesListTopGutter == rhs.includesListTopGutter
            && lhs.pendingRename == rhs.pendingRename
    }

    var body: some View {
        Group {
            if isEditingTitle {
                buttonLabel
                    .background {
                        rowChrome(pressed: false)
                    }
            } else {
                Button(action: handleRowAction) {
                    buttonLabel
                }
                .buttonStyle(QueueRowButtonStyle(isSelected: isSelected, isHovering: isHovering))
            }
        }
        .onHover { isHovering = $0 }
        .onAppear {
            if pendingRename, !isEditingTitle {
                beginEditing()
                consumePendingRename()
            }
        }
        .onChange(of: pendingRename) { pending in
            if pending {
                beginEditing()
                consumePendingRename()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .seeseeTextFocusShouldResign)) { notification in
            guard isEditingTitle else { return }
            finishEditing(reason: titleEditReason(from: notification))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }

    private func handleRowAction() {
        let reportedCount = NSApp.currentEvent?.clickCount ?? 1
        let continuesPair: Bool
        if let last = lastSelectClickAt,
           Date().timeIntervalSince(last) <= NSEvent.doubleClickInterval {
            continuesPair = true
        } else {
            continuesPair = false
        }
        let action: QueueRowMeta.TitleClickAction
        (titleClickState, action) = QueueRowMeta.handleTitleClick(
            state: titleClickState,
            isSelected: isSelected,
            clickCount: reportedCount,
            continuesPair: continuesPair
        )
        lastSelectClickAt = Date()
        switch action {
        case .beginEditing:
            beginEditing()
        case .select:
            select()
        }
    }

    private var buttonLabel: some View {
        VStack(spacing: 0) {
            if includesListTopGutter {
                SidebarQueueLayout.FirstRowTopGutter()
            }
            rowContent
        }
        .contentShape(Rectangle())
    }

    private var rowContent: some View {
        let display = DownloadProgressMemory.display(for: item, isPreviewPlayable: isPreviewPlayable)
        let meta = metaText(display)
        return HStack(spacing: 11) {
            QueueThumbnail(item: item, icon: icon, isSelected: isSelected, display: display)

            VStack(alignment: .leading, spacing: 4) {
                title

                // 下载进度只在缩略图圆环和这一行文字里，不再另加进度条，下完时行高不变。
                HStack(spacing: 5) {
                    SourceBrandMark(sourceName: item.sourceName)
                    if !meta.isEmpty {
                        Text(meta)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(item.state == .failed ? OpenMyChrome.rec : OpenMyChrome.muted)
            }

            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous))
        .opacity(item.isWatched && !isSelected ? 0.72 : 1)
    }

    @ViewBuilder
    private func rowChrome(pressed: Bool) -> some View {
        if let fill = OpenMyChrome.rowFill(selected: isSelected, pressed: pressed, hovering: isHovering) {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                .fill(fill)
                .overlay {
                    RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                        .strokeBorder(OpenMyChrome.hair)
                }
        }
    }

    @ViewBuilder
    private var title: some View {
        if isEditingTitle {
            TextField("视频标题", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($isTitleFocused)
                .onSubmit { finishEditing(reason: .submit) }
                .onExitCommand { finishEditing(reason: .escape) }
                .onChange(of: isTitleFocused) { focused in
                    if !focused, isEditingTitle {
                        finishEditing(reason: .focusLost)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(OpenMyChrome.raise, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous)
                        .strokeBorder(OpenMyChrome.fieldBorder)
                }
        } else {
            let display = item.titleDisplay
            VStack(alignment: .leading, spacing: 1) {
                Text(display.primary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OpenMyChrome.ink)
                    .lineLimit(2)
                    .truncationMode(.tail)
                // 中文译名下面一行小字是原标题，同双语字幕一个思路。
                if let secondary = display.secondary {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(OpenMyChrome.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .help("右键或双击已选中的条目可重命名")
        }
    }

    private func titleEditReason(from notification: Notification) -> QueueRowMeta.TitleEditEndReason {
        TextFocusResignReason.from(notification) == .escape ? .escape : .focusLost
    }

    private func beginEditing() {
        guard !isEditingTitle else { return }
        draftTitle = item.titleDisplay.primary
        isEditingTitle = true
        let controller = PlaybackWindowFocusController.attached(to: NSApp.keyWindow)
        controller?.setSwiftUITextFieldFocused(true)
        DispatchQueue.main.async {
            controller?.setSwiftUITextFieldFocused(true)
            isTitleFocused = true
        }
    }

    private func finishEditing(reason: QueueRowMeta.TitleEditEndReason) {
        guard isEditingTitle else { return }
        if case .save(let title) = QueueRowMeta.titleEditCommit(reason: reason, draft: draftTitle) {
            rename(title)
        }
        isEditingTitle = false
        isTitleFocused = false
    }

    private var icon: String {
        switch item.state {
        case .queued: return "clock.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .ready: return item.isWatched ? "checkmark.circle.fill" : "play.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var displaySource: String {
        item.sourceName
    }

    /// 异常态显示状态，正常态显示作者名（真信息），孤立图标会被误读成删除按钮。
    /// 下载中的文字由显示层给出：百分比、准备阶段的状态词、预览标记，不显示 yt-dlp 的原始读数。
    private func metaText(_ display: DownloadProgressDisplay.Model) -> String {
        // 失败只说「下载失败」，排队说「等待下载」，和看板卡片同一套用词；原因在右侧失败画面里。
        if item.state == .failed || !display.rowText.isEmpty,
           let status = BoardCardStatusText.value(
               isFailed: item.state == .failed,
               downloadRowText: display.rowText,
               watchedFraction: nil
           ) {
            return status.text
        }
        return item.author.isEmpty ? item.sourceName : item.author
    }
}

private struct QueueRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if let fill = OpenMyChrome.rowFill(
                    selected: isSelected,
                    pressed: configuration.isPressed,
                    hovering: isHovering
                ) {
                    RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                        .fill(fill)
                        .overlay {
                            RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                                .strokeBorder(isSelected ? OpenMyChrome.rowSelectedStroke : OpenMyChrome.hair)
                        }
                }
            }
    }
}

private struct QueueThumbnail: View {
    let item: WatchItem
    let icon: String
    let isSelected: Bool
    let display: DownloadProgressDisplay.Model

    var body: some View {
        ZStack {
            if let image = ThumbnailImageCache.image(for: item.thumbnailFileURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [OpenMyChrome.raise, OpenMyChrome.canvas],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if !display.showsRing {
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                }
            }

            if display.showsRing {
                DownloadThumbnailOverlay(display: display)
            } else if item.state == .queued {
                // 排队时没有传输发生，只压暗，不转圈；和右侧排队画面的规则一致。
                Color.black.opacity(0.22)
            }

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Spacer()
                    if let duration = item.duration, item.state == .ready {
                        Text(formatDuration(duration))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.68), in: Capsule())
                    }
                }
                .padding(5)
            }
        }
        .frame(width: 96, height: 54)
        // 缩略图是画面，和播放区一样按深色取色：还没封面时的底和下载圆环在浅色外观下也看得清。
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: OpenMyChrome.radiusMd, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusMd, style: .continuous)
                .strokeBorder(isSelected ? OpenMyChrome.ink.opacity(0.35) : OpenMyChrome.hair)
        }
        .overlay(alignment: .bottomLeading) {
            if let duration = item.duration, duration > 0, item.resumablePosition > 0 {
                GeometryReader { geometry in
                    // 进度线压在封面画面上，和画面一样固定白色，不随外观变。
                    Capsule()
                        .fill(Color.white)
                        .frame(width: geometry.size.width * min(item.resumablePosition / duration, 1), height: 3)
                }
                .frame(height: 3)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}

private struct SidebarEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.square.stack")
                .font(.system(size: 28, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("还没有视频")
                .font(.subheadline.weight(.semibold))
            Text("粘贴一个链接，存下你要看的视频。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 190)
        }
        .padding()
    }
}

private struct SubscriptionRow: View {
    let subscription: ChannelSubscription
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OpenMyChrome.muted)
                .frame(width: 18)
            Text(subscription.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OpenMyChrome.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(OpenMyChrome.faint)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("取消订阅")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 左侧栏分组头：折叠箭头在左，名字和条数，按 Paper「列表视图」画板。
private struct SidebarSectionHeader: View {
    let title: String
    let count: Int
    var isCollapsed = false
    var onToggle: (() -> Void)?

    var body: some View {
        Button {
            onToggle?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(OpenMyChrome.faint)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OpenMyChrome.muted)
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(OpenMyChrome.faint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(OpenMyChrome.canvas)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onToggle == nil)
        .help(onToggle == nil ? "" : (isCollapsed ? "展开\(title)" : "收起\(title)"))
    }
}

private struct PlayerStageLayout: Layout {
    private let topPadding: CGFloat = 12
    private let controlsSpacing: CGFloat = 13
    private let bottomPadding: CGFloat = 14

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let proposedWidth = proposal.width
        let playerSize = subviews.first?.sizeThatFits(
            ProposedViewSize(width: proposedWidth, height: nil)
        ) ?? .zero
        let controlsSize = subviews.count > 1
            ? subviews[1].sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            : .zero
        let width = proposedWidth ?? max(playerSize.width, controlsSize.width)
        let naturalHeight = topPadding
            + playerSize.height
            + (subviews.count > 1 ? controlsSpacing + controlsSize.height + bottomPadding : 0)
        return CGSize(width: width, height: proposal.height ?? naturalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let player = subviews.first else { return }
        let width = bounds.width

        guard subviews.count > 1 else {
            player.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + topPadding),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: max(0, bounds.height - topPadding))
            )
            return
        }

        let controls = subviews[1]
        let controlsSize = controls.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let playerHeight = max(
            0,
            bounds.height - topPadding - controlsSpacing - controlsSize.height - bottomPadding
        )

        player.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + topPadding),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: playerHeight)
        )
        controls.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + topPadding + playerHeight + controlsSpacing),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: controlsSize.height)
        )
    }
}

private struct PaneHeaderIconButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PaneHeaderIconLabel(systemImage: systemImage, title: title)
        }
        .watchGlassButton()
        .accessibilityLabel(title)
    }
}

/// 播放器放在哪：列表视图里视频在左、字幕栏和目录在右；看板的右侧面板里视频在上、字幕栏和目录在下。
enum VideoDetailLayout: Equatable {
    case sideBySide
    case stacked
}

private struct VideoDetail: View {
    @EnvironmentObject private var store: QueueStore
    @AppStorage(LibraryViewMode.defaultsKey) private var viewMode: LibraryViewMode = .list
    @State private var subtitleMode: SubtitleDisplayMode = .off
    @AppStorage("chaptersPresented") private var chaptersPresented = true
    @State private var seekRequest: PlayerSeekRequest?
    @State private var playback = PlaybackSnapshot.empty
    @State private var subtitleTrack: VideoSubtitleTrack?
    @State private var subtitleLoadTask: Task<Void, Never>?
    @State private var volumeHUDValue = PlaybackVolumePreference.load()
    @State private var volumeHUDVisible = false
    @State private var volumeHUDDismissalTask: Task<Void, Never>?
    @AppStorage(SponsorSkipPreference.key) private var skipSponsorsEnabled = true
    @State private var skipHUDDuration: Double?
    @State private var skipHUDVisible = false
    @State private var skipHUDDismissalTask: Task<Void, Never>?
    @State private var nowPlayingToken: UUID?
    let item: WatchItem
    let sidebarCollapsed: Bool
    let windowWidth: CGFloat
    let collapseSidebar: () -> Void
    var layout: VideoDetailLayout = .sideBySide
    /// 看板面板的收起钮；列表视图里为 nil。
    var collapsePanel: (() -> Void)?

    var body: some View {
        Group {
            chapterLayout
        }
        .navigationTitle("")
        .task(id: item.id) {
            subtitleMode = SubtitleModeStore.mode(for: item.id)
            store.rescanLocalSubtitle(for: item.id) { path in
                loadSubtitles(path: path)
            }
            collapseSidebarForNarrowChapterLayoutIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.rescanLocalSubtitle(for: item.id) { path in
                loadSubtitles(path: path)
            }
        }
        .onDisappear {
            subtitleLoadTask?.cancel()
            volumeHUDDismissalTask?.cancel()
            skipHUDDismissalTask?.cancel()
            unregisterNowPlaying()
        }
        .onAppear {
            syncNowPlaying()
            performAgentSeekIfNeeded()
        }
        .onChange(of: nowPlayingEntry) { _ in syncNowPlaying() }
        .onChange(of: store.agentSeekRequest) { _ in performAgentSeekIfNeeded() }
        .onChange(of: item.subtitleFilePath) { newPath in loadSubtitles(path: newPath) }
        .onChange(of: windowWidth) { _ in collapseSidebarForNarrowChapterLayoutIfNeeded() }
        .onChange(of: sidebarCollapsed) { isCollapsed in
            guard layout == .sideBySide, !isCollapsed, prefersOneSidePane, chaptersPresented else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                chaptersPresented = false
            }
        }
    }

    private var usesCompactToolbarActions: Bool {
        showsSidePane
    }

    private var showsSidePane: Bool {
        item.hasSidePaneContent
    }

    @ViewBuilder
    private var chapterLayout: some View {
        if layout == .stacked {
            stackedLayout
        } else if #available(macOS 14.0, *) {
            // 侧栏有没有内容都挂同一个 inspector，不切换布局分支：边下边播时章节和字幕是播放中陆续到的，
            // 换分支会让整个播放器重建（暂停、黑一下、退回上次保存的位置）。
            centerPane
                .inspector(isPresented: sidePanePresented) {
                    chapterSidebar
                        .inspectorColumnWidth(min: DigestBookChrome.minColumnWidth, ideal: 300, max: 400)
                }
        } else if !showsSidePane {
            centerPane
        } else {
            HSplitView {
                centerPane
                    .frame(minWidth: 620)

                if chaptersPresented {
                    chapterSidebar
                        .frame(minWidth: DigestBookChrome.minColumnWidth, idealWidth: 300, maxWidth: 400)
                }
            }
        }
    }

    /// 看板面板：视频在上，字幕栏和目录在下，下面一块约占面板高度的四成。
    private var stackedLayout: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                centerPane
                if sidePanePresented.wrappedValue {
                    Divider()
                    chapterSidebar
                        .frame(height: max(220, geometry.size.height * 0.42))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    /// 侧栏没有内容时不显示；用户收起或展开侧栏照旧记在 chaptersPresented 里。
    private var sidePanePresented: Binding<Bool> {
        Binding(
            get: { showsSidePane && chaptersPresented },
            set: { presented in
                guard showsSidePane else { return }
                chaptersPresented = presented
            }
        )
    }

    private var centerPane: some View {
        VStack(spacing: 0) {
            centerPaneHeader
            Divider()
            mainContent
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var centerPaneHeader: some View {
        if layout == .stacked {
            stackedPaneHeader
        } else {
            sideBySidePaneHeader
        }
    }

    /// 看板面板顶上一行：标题和频道，右边是针对这条视频的按钮和收起钮。
    private var stackedPaneHeader: some View {
        HStack(spacing: PaneHeaderIconMetrics.spacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.boardTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OpenMyChrome.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // 第二行和列表视图的详情顶栏一样：原标题在前，作者在后。
                if item.titleDisplay.secondary != nil || !item.author.isEmpty {
                    HStack(spacing: 6) {
                        if let secondary = item.titleDisplay.secondary {
                            Text(secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if !item.author.isEmpty {
                            Text(item.author)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(OpenMyChrome.muted)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            // 面板在顶栏下面，不在标题栏区域里，按钮不用 TitlebarInteractiveHost 托管；
            // 托管的按钮会浮到窗口标题栏上，盖住看板顶栏的视图切换和齿轮。
            PaneHeaderIconButton(
                systemImage: "arrow.up.forward",
                title: "打开原网页",
                action: { store.openOriginal(item.id) }
            )
            .help("打开原网页")
            PaneHeaderIconButton(
                systemImage: item.isWatched ? "arrow.uturn.backward" : "checkmark.circle",
                title: item.isWatched ? "移回队列" : "标记已看",
                action: { store.toggleWatched(item.id) }
            )
            .help(item.isWatched ? "移回队列" : "标记已看")

            if showsSidePane {
                let title = chaptersPresented ? "隐藏字幕和目录" : "显示字幕和目录"
                PaneHeaderIconButton(
                    systemImage: "rectangle.bottomthird.inset.filled",
                    title: title,
                    action: toggleChapters
                )
                .help(title)
            }

            if let collapsePanel {
                Button(action: collapsePanel) {
                    Text("esc")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OpenMyChrome.faint)
                        .frame(minWidth: PaneHeaderIconMetrics.minHitSize, minHeight: PaneHeaderIconMetrics.minHitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("收起播放器（Esc）")
                .accessibilityLabel("收起播放器")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .frame(height: OpenMyChrome.paneHeaderHeight)
    }

    private var sideBySidePaneHeader: some View {
        HStack(spacing: PaneHeaderIconMetrics.spacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.titleDisplay.primary)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(OpenMyChrome.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // 第二行：原标题（有译名或改过名时）在前，作者在后；原标题太长时截断原标题，作者留着。
                if item.titleDisplay.secondary != nil || !item.author.isEmpty {
                    HStack(spacing: 6) {
                        if let secondary = item.titleDisplay.secondary {
                            Text(secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if !item.author.isEmpty {
                            Text(item.author)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(OpenMyChrome.muted)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            titlebarActionButtons

            if showsSidePane, !chaptersPresented {
                TitlebarInteractiveHost(tooltip: "显示侧栏") {
                    PaneHeaderIconButton(
                        systemImage: "sidebar.trailing",
                        title: "显示侧栏",
                        action: toggleChapters
                    )
                }
                .fixedSize()
            }

            TitlebarInteractiveHost {
                LibraryViewModeToggle(mode: $viewMode)
            }
            .fixedSize()

            // 齿轮是整个应用的入口，放最右贴窗口边，与前面针对当前视频的按钮分开。
            TitlebarInteractiveHost(tooltip: DigestSettingsCopy.gearTitle) {
                PaneHeaderIconButton(
                    systemImage: "gearshape",
                    title: DigestSettingsCopy.gearTitle,
                    action: { DigestSettingsOpener.open() }
                )
            }
            .fixedSize()
        }
        .padding(.leading, DetailHeaderMetrics.leadingPadding(sidebarCollapsed: sidebarCollapsed))
        .padding(.trailing, 14)
        .frame(height: OpenMyChrome.paneHeaderHeight)
    }

    @ViewBuilder
    private var titlebarActionButtons: some View {
        if usesCompactToolbarActions {
            TitlebarInteractiveHost(tooltip: "打开原网页") {
                PaneHeaderIconButton(
                    systemImage: "arrow.up.forward",
                    title: "打开原网页",
                    action: { store.openOriginal(item.id) }
                )
            }
            .fixedSize()
            TitlebarInteractiveHost(tooltip: item.isWatched ? "移回队列" : "标记已看") {
                PaneHeaderIconButton(
                    systemImage: item.isWatched ? "arrow.uturn.backward" : "checkmark.circle",
                    title: item.isWatched ? "移回队列" : "标记已看",
                    action: { store.toggleWatched(item.id) }
                )
            }
            .fixedSize()
        } else {
            TitlebarInteractiveHost {
                HStack(spacing: PaneHeaderIconMetrics.spacing) {
                    Button {
                        store.openOriginal(item.id)
                    } label: {
                        Label("打开原网页", systemImage: "arrow.up.forward")
                            .frame(minHeight: PaneHeaderIconMetrics.minHitSize)
                            .contentShape(Rectangle())
                    }
                    .watchGlassButton()
                    .accessibilityLabel("打开原网页")

                    Button {
                        store.toggleWatched(item.id)
                    } label: {
                        Label(
                            item.isWatched ? "移回队列" : "标记已看",
                            systemImage: item.isWatched ? "arrow.uturn.backward" : "checkmark.circle"
                        )
                        .frame(minHeight: PaneHeaderIconMetrics.minHitSize)
                        .contentShape(Rectangle())
                    }
                    .watchGlassButton()
                    .accessibilityLabel(item.isWatched ? "移回队列" : "标记已看")
                }
            }
            .fixedSize()
        }
    }

    private var mainContent: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - 32)

            ZStack {
                DetailBackdrop(thumbnailURL: item.thumbnailFileURL)
                    .equatable()

                PlayerStageLayout {
                    playerSurface

                    if isItemPlayable {
                        PlaybackControls(
                            snapshot: playback,
                            knownDuration: item.duration,
                            chapters: item.availableChapters,
                            togglePlayback: { PlaybackCommandCenter.shared.togglePlayback() },
                            skip: { PlaybackCommandCenter.shared.skip(by: $0) },
                            seek: seekToTime,
                            toggleMute: { PlaybackCommandCenter.shared.toggleMute() },
                            setPlaybackRate: { PlaybackCommandCenter.shared.setPlaybackRate(to: $0) },
                            hasSubtitles: subtitleTrack != nil,
                            subtitleMode: subtitleMode,
                            toggleSubtitles: cycleSubtitleMode,
                            showsSponsorSkipToggle: YouTubeVideoID.extract(from: item.urlString) != nil,
                            skipSponsorsEnabled: skipSponsorsEnabled,
                            toggleSponsorSkip: { skipSponsorsEnabled.toggle() },
                            previewBadge: downloadDisplay.previewBadge,
                            previewFraction: downloadDisplay.ringFraction
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: contentWidth, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
    }

    private var chapterSidebar: some View {
        ChapterSidebar(
            itemID: item.id,
            chapters: item.availableChapters,
            subtitleCues: subtitleTrack?.cues ?? [],
            itemDuration: item.duration,
            hasSubtitleSource: item.subtitleFileURL != nil || subtitleTrack != nil,
            currentTime: playback.currentTime,
            isPlaying: playback.isPlaying,
            isPresented: chaptersPresented,
            toggle: toggleChapters,
            jumpAndPlay: jumpAndPlay,
            showsHeader: layout == .sideBySide
        )
        .ignoresSafeArea(.container, edges: .top)
    }

    private var playerSurface: some View {
        ZStack(alignment: .bottom) {
            Group {
                if store.isMediaFolderDisconnected, displayedItem.state == .ready {
                    disconnectedPlaybackState
                } else if let mediaURL = playbackSource.url {
                    // 不按地址重建播放器：在线预览下完换成本地文件时，播放器原地换片段，位置和全屏都不丢。
                    GeometryReader { geometry in
                        LocalVideoPlayer(
                            url: mediaURL,
                            title: item.titleDisplay.primary,
                            originalTitle: item.titleDisplay.secondary,
                            author: item.author,
                            resumeAt: item.resumablePosition,
                            seekRequest: seekRequest,
                            subtitleTrack: subtitleTrack,
                            subtitleMode: subtitleMode,
                            sourceURLString: item.urlString,
                            skipSponsorsEnabled: skipSponsorsEnabled,
                            onProgress: { seconds, isPlaying in store.updatePlaybackPosition(seconds, for: item.id, whilePlaying: isPlaying) },
                            onPlaybackEvent: { store.handlePlaybackEvent($0, for: item.id) },
                            onStateChange: { playback = $0 },
                            onVolumeChange: showVolumeHUD,
                            onSponsorSkip: showSkipHUD,
                            onEnded: { store.markWatched(item.id) },
                            onUnavailable: { store.discardProgressivePlayback(for: item.id) }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                } else {
                    downloadState
                }
            }

            if skipHUDVisible, let skipHUDDuration {
                PlayerSkipHUD(skippedDuration: skipHUDDuration)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else if volumeHUDVisible {
                PlayerVolumeHUD(
                    volume: volumeHUDValue,
                    isMuted: playback.isMuted || volumeHUDValue <= 0
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color.black)
        // 画面区域在浅色外观下也是黑底：画面上的提示框、等待画面和按钮一律按深色取色。
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: OpenMyChrome.radiusXl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusXl, style: .continuous)
                .strokeBorder(OpenMyChrome.hair)
        }
    }

    /// 给本机查询通道登记的当前条目；条件与 playerSurface 挂出 LocalVideoPlayer 的条件一致。
    /// 预览阶段登记的是在线预览地址。
    private var nowPlayingEntry: NowPlayingEntry? {
        guard !(store.isMediaFolderDisconnected && displayedItem.state == .ready),
              let mediaURL = playbackSource.url else { return nil }
        return NowPlayingEntry(item: displayedItem, fileURL: mediaURL, subtitleTrack: subtitleTrack)
    }

    private func syncNowPlaying() {
        guard let entry = nowPlayingEntry else {
            unregisterNowPlaying()
            return
        }
        if let nowPlayingToken, NowPlayingRegistry.shared.update(nowPlayingToken, entry: entry) {
            return
        }
        nowPlayingToken = NowPlayingRegistry.shared.register(entry)
    }

    private func unregisterNowPlaying() {
        guard let nowPlayingToken else { return }
        NowPlayingRegistry.shared.unregister(nowPlayingToken)
        self.nowPlayingToken = nil
    }

    /// 直接读队列当前值，不靠 `let item` 的 onChange 边沿。
    private var displayedItem: WatchItem {
        store.items.first(where: { $0.id == item.id }) ?? item
    }

    /// 右侧该播的片源：下载中的在线预览、下完的本地文件，或者都没有（显示等待画面）。
    private var playbackSource: PlayerReadyDecision.Source {
        store.playbackSource(for: displayedItem)
    }

    private var isItemPlayable: Bool {
        playbackSource.url != nil
    }

    /// - Parameter path: 显式路径（重扫回调 / onChange）；nil 时回落到当前 `item`。
    private func loadSubtitles(path: String? = nil) {
        subtitleLoadTask?.cancel()
        subtitleTrack = nil
        let subtitleURL: URL?
        if let path {
            guard !path.isEmpty else { return }
            let url = URL(fileURLWithPath: path)
            subtitleURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        } else {
            subtitleURL = item.subtitleFileURL
        }
        guard let subtitleURL else { return }
        subtitleLoadTask = Task {
            let track = await Task.detached(priority: .utility) {
                VideoSubtitleTrack(contentsOf: subtitleURL)
            }.value
            guard !Task.isCancelled else { return }
            subtitleTrack = track
        }
    }

    private func showSkipHUD(_ skippedDuration: Double) {
        skipHUDDismissalTask?.cancel()
        skipHUDDuration = skippedDuration
        withAnimation(volumeHUDAnimation) {
            skipHUDVisible = true
        }
        skipHUDDismissalTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(volumeHUDAnimation) {
                skipHUDVisible = false
            }
        }
    }

    private func showVolumeHUD(_ volume: Double) {
        volumeHUDDismissalTask?.cancel()
        volumeHUDValue = PlaybackVolumePreference.normalized(volume)
        withAnimation(volumeHUDAnimation) {
            volumeHUDVisible = true
        }
        volumeHUDDismissalTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(volumeHUDAnimation) {
                volumeHUDVisible = false
            }
        }
    }

    private var volumeHUDAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : .easeOut(duration: 0.15)
    }

    private var disconnectedPlaybackState: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.28), Color.black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 38, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                Text(MediaFolderCopy.disconnected)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityLabel(MediaFolderCopy.disconnected)
                Text(DigestSettingsCopy.displayPath(store.mediaFolder))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(40)
        }
    }

    @ViewBuilder
    private var downloadState: some View {
        ZStack {
            if let image = ThumbnailImageCache.image(for: item.thumbnailFileURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 22)
                    .opacity(0.38)
            }
            LinearGradient(
                colors: [Color.black.opacity(0.28), Color.black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 15) {
                if item.state != .downloading {
                    statusHeader
                }
                if item.state == .downloading {
                    DownloadWaitingStack(display: downloadDisplay)
                } else if item.state == .failed {
                    Text(QueueRowMeta.failureSummary(from: item.errorMessage))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                    if let rawError = item.errorMessage, !rawError.isEmpty {
                        DisclosureGroup("详情") {
                            Text(rawError)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.55))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: 480, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(.top, 6)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: 200)
                    }
                    Button {
                        store.startDownload(for: item.id)
                    } label: {
                        Text("重试下载")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                    .watchGlassButton(prominent: true)
                } else if item.state == .queued {
                    // 排队与重试倒计时期间没有传输发生，不放转圈，直说状态。
                    Text(item.progressLabel.isEmpty ? "排队中" : item.progressLabel)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.68))
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .padding(40)
        }
    }

    /// 队列行、缩略图、等待画面和预览标记读同一份下载显示，进度彼此对得上。
    private var downloadDisplay: DownloadProgressDisplay.Model {
        DownloadProgressMemory.display(for: displayedItem, isPreviewPlayable: store.isPreviewPlayable(item.id))
    }

    /// 排队、失败等画面顶部的图标和标题；下载中由圆环画面自己带标题。
    private var statusHeader: some View {
        Group {
            Image(systemName: stateIcon)
                .font(.system(size: 38, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
            Text(stateTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    private var stateIcon: String {
        switch item.state {
        case .failed: return "exclamationmark.triangle.fill"
        case .queued: return "clock.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    /// 标题不假装在动：倒计时与排队期用等待时态，真正传输时才是进行时。
    private var stateTitle: String {
        switch item.state {
        case .failed: return "下载失败"
        case .queued: return item.progressLabel.contains("重试") ? "等待重试" : "排队等待"
        default: return "正在存到本地"
        }
    }

    private func seekToChapter(_ chapter: VideoChapter) {
        seekRequest = PlayerSeekRequest(time: chapter.startTime, shouldPlay: playback.isPlaying)
        store.updatePlaybackPosition(chapter.startTime, for: item.id)
        // 暂停时播放器未必立刻回推进度；乐观写入快照，侧栏/字幕立刻对齐目标时刻。
        applyPlaybackTimeOptimistically(chapter.startTime)
    }

    /// 字幕三档循环：双语、仅译文、关，逐视频记忆。
    private func cycleSubtitleMode() {
        subtitleMode = subtitleMode.next
        SubtitleModeStore.set(subtitleMode, for: item.id)
    }

    private func seekToTime(_ time: Double) {
        seekRequest = PlayerSeekRequest(
            time: time,
            shouldPlay: DigestJumpPlayback.scrubShouldPlay(currentlyPlaying: playback.isPlaying)
        )
        store.updatePlaybackPosition(time, for: item.id)
        applyPlaybackTimeOptimistically(time)
    }

    /// agent 经 MCP 发来的 `seek_to`：只认这一条的请求，跳完清掉。
    /// 同时写进观看进度，播放器还没建好时按续播位置打开在这一秒。
    private func performAgentSeekIfNeeded() {
        guard let request = store.agentSeekRequest, request.itemID == item.id else { return }
        seekRequest = PlayerSeekRequest(time: request.seconds, shouldPlay: request.play)
        store.updatePlaybackPosition(request.seconds, for: item.id)
        applyPlaybackTimeOptimistically(request.seconds)
        store.finishAgentSeekRequest(request.id)
    }

    private func jumpAndPlay(_ time: Double) {
        seekRequest = PlayerSeekRequest(
            time: time,
            shouldPlay: DigestJumpPlayback.jumpShouldPlay()
        )
        store.updatePlaybackPosition(time, for: item.id)
        applyPlaybackTimeOptimistically(time)
    }

    private func applyPlaybackTimeOptimistically(_ time: Double) {
        guard time.isFinite else { return }
        guard abs(playback.currentTime - time) > 0.001 else { return }
        playback.currentTime = time
    }

    private func toggleChapters() {
        let willShow = !chaptersPresented
        if layout == .sideBySide, willShow, prefersOneSidePane, !sidebarCollapsed {
            collapseSidebar()
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            chaptersPresented = willShow
        }
    }

    private var prefersOneSidePane: Bool {
        windowWidth < 1160 && showsSidePane
    }

    private func collapseSidebarForNarrowChapterLayoutIfNeeded() {
        guard layout == .sideBySide, prefersOneSidePane, chaptersPresented, !sidebarCollapsed else { return }
        collapseSidebar()
    }
}

private struct QueueBackupFailureBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundStyle(OpenMyChrome.rec)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OpenMyChrome.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OpenMyChrome.raise, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous)
                .strokeBorder(OpenMyChrome.hair)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

private struct MediaFolderDisconnectedBanner: View {
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundStyle(OpenMyChrome.rec)
            VStack(alignment: .leading, spacing: 2) {
                Text(MediaFolderCopy.disconnected)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OpenMyChrome.ink)
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OpenMyChrome.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OpenMyChrome.raise, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous)
                .strokeBorder(OpenMyChrome.hair)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(MediaFolderCopy.disconnected) \(path)")
    }
}

private struct DetailBackdrop: View, Equatable {
    let thumbnailURL: URL?
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: DetailBackdrop, rhs: DetailBackdrop) -> Bool {
        lhs.thumbnailURL == rhs.thumbnailURL
    }

    var body: some View {
        ZStack {
            OpenMyChrome.canvas

            if let image = ThumbnailImageCache.image(for: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 90)
                    .saturation(0.4)
                    // 浅色底上深色封面会把底压灰，和控制条的 raise 底色混在一起，浅色下减半。
                    .opacity(colorScheme == .dark ? 0.06 : 0.03)
                    .scaleEffect(1.15)
            }
        }
    }
}

private struct PlayerSkipHUD: View {
    let skippedDuration: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "forward.end.fill")
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            Text(SponsorSkipMessage.text(skippedDuration: skippedDuration))
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(OpenMyChrome.raise, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                .strokeBorder(OpenMyChrome.hair)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SponsorSkipMessage.text(skippedDuration: skippedDuration))
    }
}

private struct PlayerVolumeHUD: View {
    let volume: Double
    let isMuted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 26)

            ProgressView(value: isMuted ? 0 : volume)
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 112)

            Text("\(Int(((isMuted ? 0 : volume) * 100).rounded()))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 38, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(OpenMyChrome.raise, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                .strokeBorder(OpenMyChrome.hair)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音量")
        .accessibilityValue(isMuted ? "已静音" : "百分之 \(Int((volume * 100).rounded()))")
    }

    private var symbolName: String {
        if isMuted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private struct PlaybackControls: View {
    let snapshot: PlaybackSnapshot
    let knownDuration: Double?
    let chapters: [VideoChapter]
    let togglePlayback: () -> Void
    let skip: (Double) -> Void
    let seek: (Double) -> Void
    let toggleMute: () -> Void
    let setPlaybackRate: (Double) -> Void
    let hasSubtitles: Bool
    let subtitleMode: SubtitleDisplayMode
    let toggleSubtitles: () -> Void
    let showsSponsorSkipToggle: Bool
    let skipSponsorsEnabled: Bool
    let toggleSponsorSkip: () -> Void
    /// 正在播预览、完整画质还在下载时的标记文字，例如「预览 62%」；其他时候为 nil。
    var previewBadge: String? = nil
    var previewFraction: Double? = nil

    private var subtitleModeHelp: String {
        switch subtitleMode {
        case .bilingual: return "双语字幕，点击换成仅译文"
        case .translationOnly: return "仅显示译文，点击关闭字幕"
        case .off: return "字幕已关，点击打开双语字幕"
        }
    }
    @State private var scrubTime: Double?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(showRemainingTime: true, spacing: 10)
            controlRow(showRemainingTime: false, spacing: 6)
            compactControlLayout
            narrowControlLayout
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .watchGlass(.regular, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusXl, style: .continuous))
    }

    private func controlRow(showRemainingTime: Bool, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            transportControls
            timeline(showRemainingTime: showRemainingTime)
            utilityControls
        }
    }

    private var compactControlLayout: some View {
        VStack(spacing: 2) {
            timeline(showRemainingTime: false)

            HStack(spacing: 6) {
                transportControls
                Spacer(minLength: 4)
                utilityControls
            }
        }
    }

    private var narrowControlLayout: some View {
        VStack(spacing: 4) {
            timeline(showRemainingTime: false)
            transportControls
            utilityControls
        }
        .frame(maxWidth: .infinity)
    }

    private var transportControls: some View {
        WatchGlassContainer(spacing: 4) {
            HStack(spacing: 3) {
                PlayerControlButton(
                    systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill",
                    help: snapshot.isPlaying ? "暂停（空格键）" : "播放（空格键）",
                    isPrimary: true,
                    action: togglePlayback
                )
                PlayerControlButton(systemImage: "gobackward.10", help: "后退 10 秒（左方向键）") {
                    skip(-10)
                }
                PlayerControlButton(systemImage: "goforward.10", help: "前进 10 秒（右方向键）") {
                    skip(10)
                }
            }
        }
        .fixedSize()
    }

    private var utilityControls: some View {
        HStack(spacing: 6) {
            if let previewBadge {
                DownloadPreviewBadge(text: previewBadge, fraction: previewFraction)
                    .transition(.opacity)
            }

            PlaybackSpeedMenu(
                playbackRate: snapshot.playbackRate,
                select: setPlaybackRate
            )

            if showsSponsorSkipToggle {
                SponsorSkipPill(isOn: skipSponsorsEnabled, action: toggleSponsorSkip)
            }

            PlayerControlButton(
                systemImage: subtitleMode == .translationOnly ? "character.bubble" : "captions.bubble",
                help: hasSubtitles ? subtitleModeHelp : "没有可用的字幕",
                isEnabled: hasSubtitles,
                isSelected: subtitleMode != .off && hasSubtitles,
                action: toggleSubtitles
            )

            AirPlayRoutePicker()
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(snapshot.isExternalPlaybackActive
                            ? Color.primary.opacity(0.12)
                            : Color.primary.opacity(0.01))
                }
                .help(snapshot.isExternalPlaybackActive ? "AirPlay 已连接" : "选择 AirPlay 设备")

            PlayerControlButton(
                systemImage: snapshot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                help: snapshot.isMuted ? "取消静音" : "静音",
                action: toggleMute
            )
        }
        .fixedSize()
        // 完整画质下完，标记 0.25 秒淡出。
        .animation(.easeInOut(duration: 0.25), value: previewBadge == nil)
    }

    @ViewBuilder
    private func timeline(showRemainingTime: Bool) -> some View {
        HStack(spacing: 6) {
            Text(formatTime(displayTime))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 46, alignment: .trailing)

            ChapterScrubber(
                value: min(displayTime, effectiveDuration),
                duration: effectiveDuration,
                chapters: chapters,
                scrubChanged: { scrubTime = $0 },
                scrubEnded: { time in
                    seek(time)
                    scrubTime = nil
                }
            )
            .frame(minWidth: 80, maxWidth: .infinity)
            .frame(height: 44)
            .disabled(effectiveDuration <= 0)

            if showRemainingTime {
                Text("−\(formatTime(max(0, effectiveDuration - displayTime)))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .leading)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var effectiveDuration: Double {
        max(snapshot.duration, knownDuration ?? 0)
    }

    private var displayTime: Double {
        scrubTime ?? snapshot.currentTime
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}

private struct PlaybackSpeedMenu: View {
    let playbackRate: Double
    let select: (Double) -> Void

    var body: some View {
        Menu {
            ForEach(PlaybackRatePolicy.supportedRates, id: \.self) { rate in
                Button {
                    select(rate)
                } label: {
                    if rate == normalizedRate {
                        Label(rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(rate))
                    }
                }
            }
        } label: {
            Text(rateLabel(normalizedRate))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(normalizedRate == 1.0 ? 0.85 : 1))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background {
                    // 非常速属于异常态，轻微着色提醒，常速保持沉默。
                    if normalizedRate != 1.0 {
                        Capsule().fill(Color.primary.opacity(0.08))
                    }
                }
            .contentShape(Capsule())
            .watchGlass(.clear, interactive: true, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.07))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择播放速度（上下方向键每次调 0.1×）")
        .accessibilityLabel("播放速度")
        .accessibilityValue(rateLabel(normalizedRate))
    }

    private var normalizedRate: Double {
        PlaybackRatePolicy.normalized(playbackRate)
    }

    private func rateLabel(_ rate: Double) -> String {
        String(format: "%.1f×", rate)
    }
}

/// 跳赞助段开关：文字胶囊，与倍速胶囊同款；图标版会被当成「下一章」。
private struct SponsorSkipPill: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("跳赞助")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(isOn ? 1 : 0.45))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background {
                    if isOn {
                        Capsule().fill(Color.primary.opacity(0.08))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .watchGlass(.clear, interactive: true, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.07))
        }
        .fixedSize()
        .help(isOn ? "正在自动跳过赞助段，点击关闭" : "已关闭自动跳过赞助段，点击打开")
        .accessibilityLabel("跳过赞助段")
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct ChapterTimelineSegment: Identifiable {
    let startTime: Double
    let endTime: Double
    let title: String
    let isChapter: Bool

    var id: String { "\(startTime)-\(title)" }
}

private struct ChapterScrubber: View {
    let value: Double
    let duration: Double
    let chapters: [VideoChapter]
    let scrubChanged: (Double) -> Void
    let scrubEnded: (Double) -> Void
    @State private var hoverTime: Double?
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let previewTime = hoverTime.map { min(max(0, $0), duration) }
            let timelineSegments = segments
            let currentChapterTime = namedChapterTime(
                min(max(0, value), duration),
                in: timelineSegments
            )
            let displayedPillTime = previewTime.flatMap {
                namedChapterTime($0, in: timelineSegments)
            } ?? currentChapterTime

            ZStack(alignment: .topLeading) {
                if let displayedPillTime {
                    chapterPopover(time: displayedPillTime, width: width, segments: timelineSegments)
                }

                timelineTrack(width: width, segments: timelineSegments)
                    .frame(width: width, height: 8, alignment: .leading)
                    .offset(y: 31)

                Circle()
                    .fill(OpenMyChrome.ink)
                    .overlay {
                        Circle().strokeBorder(OpenMyChrome.canvas, lineWidth: 2)
                    }
                    .frame(width: 13, height: 13)
                    .position(x: thumbPosition(for: value, width: width), y: 35)

                if let previewTime, !isDragging {
                    Circle()
                        .fill(Color.primary.opacity(0.8))
                        .overlay {
                            Circle().strokeBorder(OpenMyChrome.canvas, lineWidth: 1.5)
                        }
                        .frame(width: 8, height: 8)
                        .position(x: xPosition(for: previewTime, width: width), y: 35)
                }
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        guard duration > 0 else { return }
                        isDragging = true
                        let time = time(for: gesture.location.x, width: width)
                        hoverTime = time
                        scrubChanged(time)
                    }
                    .onEnded { gesture in
                        guard duration > 0 else { return }
                        let time = time(for: gesture.location.x, width: width)
                        scrubChanged(time)
                        scrubEnded(time)
                        isDragging = false
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard duration > 0 else { return }
                    hoverTime = time(for: location.x, width: width)
                case .ended:
                    if !isDragging { hoverTime = nil }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(formatTime(value))，共 \(formatTime(duration))")
    }

    private func timelineTrack(width: CGFloat, segments: [ChapterTimelineSegment]) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                let geometry = segmentGeometry(
                    segment,
                    index: index,
                    width: width,
                    segmentCount: segments.count
                )

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(isActive(segment) ? 0.22 : 0.12))
                    .frame(width: geometry.width, height: 8)
                    .offset(x: geometry.x)

                if geometry.filledWidth > 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(OpenMyChrome.ink)
                        .frame(width: geometry.filledWidth, height: 8)
                        .offset(x: geometry.x)
                }
            }
        }
    }

    private func chapterPopover(
        time: Double,
        width: CGFloat,
        segments: [ChapterTimelineSegment]
    ) -> some View {
        let title = segment(at: time, in: segments)?.title ?? "视频"
        let estimatedTitleWidth = title.reduce(CGFloat(28)) { $0 + ($1.isASCII ? 6.6 : 12) }
        let popoverWidth = min(max(1, width), min(420, max(150, estimatedTitleWidth)))
        let halfWidth = popoverWidth / 2
        let anchor = xPosition(for: time, width: width)
        let popoverOrigin = min(max(0, anchor - halfWidth), max(0, width - popoverWidth))
        let pointerLimit = max(0, halfWidth - 14)
        let pointerOffset = min(
            max(anchor - popoverOrigin - halfWidth, -pointerLimit),
            pointerLimit
        )

        return VStack(spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .lineSpacing(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                .foregroundStyle(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .frame(width: popoverWidth, alignment: .leading)
                .watchGlass(.regular, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusMd, style: .continuous))

            Capsule()
                .fill(OpenMyChrome.ink.opacity(0.85))
                .frame(width: 2, height: 6)
                .offset(x: pointerOffset)
        }
        .frame(width: popoverWidth)
        .offset(x: popoverOrigin)
        .fixedSize(horizontal: false, vertical: true)
        .alignmentGuide(.top) { dimensions in
            dimensions[.bottom] - 27
        }
        .allowsHitTesting(false)
    }

    private var segments: [ChapterTimelineSegment] {
        guard duration > 0 else { return [] }
        let sorted = chapters
            .filter {
                $0.startTime.isFinite
                    && $0.startTime >= 0
                    && $0.startTime < duration
                    && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.startTime < $1.startTime }

        var unique: [VideoChapter] = []
        for chapter in sorted where unique.last.map({ abs($0.startTime - chapter.startTime) > 0.01 }) ?? true {
            unique.append(chapter)
        }
        guard !unique.isEmpty else {
            return [ChapterTimelineSegment(
                startTime: 0,
                endTime: duration,
                title: "视频",
                isChapter: false
            )]
        }

        var result: [ChapterTimelineSegment] = []
        if let first = unique.first, first.startTime > 0.01 {
            result.append(ChapterTimelineSegment(
                startTime: 0,
                endTime: first.startTime,
                title: "视频",
                isChapter: false
            ))
        }
        for index in unique.indices {
            let start = unique[index].startTime
            let end = index + 1 < unique.count ? unique[index + 1].startTime : duration
            guard end > start else { continue }
            result.append(ChapterTimelineSegment(
                startTime: start,
                endTime: end,
                title: unique[index].title,
                isChapter: true
            ))
        }
        return result
    }

    private func namedChapterTime(
        _ time: Double,
        in segments: [ChapterTimelineSegment]
    ) -> Double? {
        guard segment(at: time, in: segments)?.isChapter == true else { return nil }
        return time
    }

    private func segment(
        at time: Double,
        in segments: [ChapterTimelineSegment]
    ) -> ChapterTimelineSegment? {
        segments.last { time >= $0.startTime && time < $0.endTime } ?? segments.last
    }

    private func segmentGeometry(
        _ segment: ChapterTimelineSegment,
        index: Int,
        width: CGFloat,
        segmentCount: Int
    ) -> (x: CGFloat, width: CGFloat, filledWidth: CGFloat) {
        let gap: CGFloat = segmentCount > 1 ? 5 : 0
        let rawStart = xPosition(for: segment.startTime, width: width)
        let rawEnd = xPosition(for: segment.endTime, width: width)
        let leadingGap = index == 0 ? 0 : gap / 2
        let trailingGap = index == segmentCount - 1 ? 0 : gap / 2
        let x = rawStart + leadingGap
        let segmentWidth = max(1, rawEnd - rawStart - leadingGap - trailingGap)
        let filledEnd = xPosition(for: min(max(value, segment.startTime), segment.endTime), width: width)
        let filledWidth = min(segmentWidth, max(0, filledEnd - x))
        return (x, segmentWidth, filledWidth)
    }

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return width * CGFloat(min(max(0, time / duration), 1))
    }

    private func thumbPosition(for time: Double, width: CGFloat) -> CGFloat {
        min(max(6.5, xPosition(for: time, width: width)), max(6.5, width - 6.5))
    }

    private func isActive(_ segment: ChapterTimelineSegment) -> Bool {
        value >= segment.startTime && value < segment.endTime
    }

    private func time(for x: CGFloat, width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        return duration * Double(min(max(0, x / width), 1))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}

private struct PlayerControlButton: View {
    let systemImage: String
    let help: String
    var isPrimary = false
    var isEnabled = true
    var isSelected = false
    let action: () -> Void
    @State private var isHovering = false

    private let controlSize: CGFloat = 32

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(isPrimary || isSelected ? 1 : 0.85))
                .frame(width: controlSize, height: controlSize)
                .background {
                    Circle()
                        .fill(buttonBackground)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.34)
        .scaleEffect(isHovering && isEnabled ? 1.04 : 1)
        .animation(.easeOut(duration: 0.13), value: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
    }

    private var buttonBackground: Color {
        if isPrimary || isSelected { return OpenMyChrome.raise }
        return isHovering && isEnabled ? OpenMyChrome.raise.opacity(0.7) : OpenMyChrome.canvas.opacity(0.01)
    }
}

private struct ChapterSidebar: View {
    let itemID: UUID
    let chapters: [VideoChapter]
    let subtitleCues: [VideoSubtitleCue]
    let itemDuration: Double?
    let hasSubtitleSource: Bool
    let currentTime: Double
    let isPlaying: Bool
    let isPresented: Bool
    let toggle: () -> Void
    let jumpAndPlay: (Double) -> Void
    /// 看板面板里字幕栏排在视频下面，收起钮在面板顶上一行，不再单占一条 56 点的头。
    var showsHeader = true

    @State private var activeCueIndex: Int?
    @State private var displayCues: [VideoSubtitleCue] = []
    @State private var autoFollowSuspendedUntil = Date.distantPast
    @State private var ignoreLiveScrollUntil = Date.distantPast
    /// 递增以触发 ScrollViewReader 滚到当前句（含暂停结束后的定时恢复）。
    @State private var followScrollToken = 0
    @State private var resumeFollowTask: Task<Void, Never>?
    /// 用于识别 seek 造成的非连续时间跳变（相对上一帧 currentTime）。
    @State private var lastTrackedTime = Double.nan
    @State private var searchQuery = ""
    @State private var searchActive = 0
    @State private var searchScrollToken = 0
    @State private var focusedCueIndex: Int?
    @State private var focusScrollToken = 0
    @State private var tocExpanded = false

    private let autoFollowResumeDelay: TimeInterval = 4
    /// 超过该间隔的时间跳变视为 seek，立刻恢复高亮跟随。
    private let seekJumpThreshold: TimeInterval = 1.25

    private var searchHits: [Int] {
        DigestTranscriptSearch.matchingCueIndices(in: displayCues, query: searchQuery)
    }

    private var visibleBookIndices: [Int] {
        Array(displayCues.indices)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                header
                Divider()
            }
            lyricsList
        }
        .background(OpenMyChrome.canvas)
        .coordinateSpace(name: "digest-book-page")
        .onAppear {
            displayCues = SubtitleSentenceBlocks.aggregate(subtitleCues)
            lastTrackedTime = currentTime
            refreshActiveCue(at: currentTime)
            refreshDigestKeyboardAvailability()
        }
        .onDisappear {
            resumeFollowTask?.cancel()
            resumeFollowTask = nil
            DigestCommandCenter.shared.bookAvailable = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .seeseeDigestKeyboard)) { note in
            guard let action = note.object as? DigestKeyboardAction else { return }
            applyDigestKeyboard(action)
        }
        .onChange(of: currentTime) { newTime in
            // 含暂停态 seek 的乐观时间更新：按目标时刻立刻重算高亮。
            refreshActiveCue(at: newTime)
        }
        .onChange(of: subtitleCues) { newCues in
            displayCues = SubtitleSentenceBlocks.aggregate(newCues)
            activeCueIndex = nil
            lastTrackedTime = Double.nan
            refreshActiveCue(at: currentTime)
        }
        .onChange(of: searchQuery) { _ in
            searchActive = 0
            if !searchHits.isEmpty {
                searchScrollToken &+= 1
            }
        }
        .onChange(of: isPlaying) { playing in
            if playing {
                tocExpanded = false
            }
        }
        .onChange(of: itemID) { _ in
            searchQuery = ""
            searchActive = 0
            focusedCueIndex = nil
            tocExpanded = false
        }
        .onChange(of: displayCues.count) { _ in
            refreshDigestKeyboardAvailability()
        }
        .onChange(of: isPresented) { _ in
            refreshDigestKeyboardAvailability()
        }
    }

    /// 时级视频的时间码是 h:mm:ss，按内容预留列宽，避免切换时整列推移。
    private var timeColumnWidth: CGFloat {
        let needsHours = chapters.contains { $0.startTime >= 3600 }
            || subtitleCues.contains { $0.startTime >= 3600 }
        return needsHours ? 64 : 52
    }

    /// 目录只列视频自带的章节。
    private var tocChapters: [VideoChapter] {
        DigestTOCChapters.listed(chapters)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 8)

            if isPresented {
                TitlebarInteractiveHost(tooltip: "隐藏侧栏") {
                    PaneHeaderIconButton(
                        systemImage: "sidebar.trailing",
                        title: "隐藏侧栏",
                        action: toggle
                    )
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: OpenMyChrome.paneHeaderHeight)
    }

    @ViewBuilder
    private var lyricsList: some View {
        if !DigestCopy.showsBook(cueCount: subtitleCues.count) {
            sidePaneEmptyState(
                title: DigestCopy.emptyTitle,
                detail: DigestCopy.emptyDetail(hasSubtitleSource: hasSubtitleSource)
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if DigestCopy.showsDigestActions(cueCount: displayCues.count) {
                    DigestBookToolbar(
                        query: searchQuery,
                        onQueryChange: { searchQuery = $0 },
                        matchCount: searchHits.count,
                        activeIndex: searchHits.isEmpty ? nil : searchActive,
                        step: stepSearch
                    )
                }
                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: DigestCueDisplay.blockSpacing) {
                                if !displayCues.isEmpty && !tocChapters.isEmpty {
                                    DigestTOCBanner(
                                        chapters: tocChapters,
                                        duration: itemDuration ?? tocChapters.last?.endTime,
                                        isExpanded: tocExpanded,
                                        currentTime: currentTime,
                                        timeColumnWidth: timeColumnWidth,
                                        onToggleExpand: { tocExpanded.toggle() },
                                        onSeek: seekFromTOC
                                    )
                                }
                                ForEach(visibleBookIndices, id: \.self) { index in
                                    bookCueRow(index: index)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background {
                                SidePaneScrollActivityMonitor {
                                    noteUserScroll()
                                }
                                .frame(width: 0, height: 0)
                            }
                        }
                        .scrollIndicators(.hidden)
                        .onAppear {
                            refreshActiveCue(at: currentTime)
                            if let activeCueIndex {
                                DispatchQueue.main.async {
                                    scrollToCue(activeCueIndex, proxy: proxy)
                                }
                            }
                        }
                        .onChange(of: activeCueIndex) { newIndex in
                            guard Date() >= autoFollowSuspendedUntil,
                                  newIndex != nil else { return }
                            followScrollToken &+= 1
                        }
                        .onChange(of: followScrollToken) { _ in
                            guard let activeCueIndex else { return }
                            guard Date() >= autoFollowSuspendedUntil else { return }
                            guard visibleBookIndices.contains(activeCueIndex) else { return }
                            scrollToCue(activeCueIndex, proxy: proxy)
                        }
                        .onChange(of: searchScrollToken) { _ in
                            guard searchHits.indices.contains(searchActive) else { return }
                            let index = searchHits[searchActive]
                            guard visibleBookIndices.contains(index) else { return }
                            scrollToCue(index, proxy: proxy)
                        }
                        .onChange(of: focusScrollToken) { _ in
                            guard let focusedCueIndex,
                                  visibleBookIndices.contains(focusedCueIndex) else { return }
                            scrollToCue(focusedCueIndex, proxy: proxy)
                        }
                    }
                }
            }
        }
    }

    private func refreshDigestKeyboardAvailability() {
        DigestCommandCenter.shared.bookAvailable =
            DigestCopy.showsDigestActions(cueCount: displayCues.count) && isPresented
    }

    private func applyDigestKeyboard(_ action: DigestKeyboardAction) {
        switch action {
        case .passThrough:
            break
        case .moveFocus(let delta):
            focusedCueIndex = DigestKeyboardFocus.moving(
                from: focusedCueIndex,
                visible: visibleBookIndices,
                delta: delta,
                playing: activeCueIndex
            )
            if focusedCueIndex != nil {
                focusScrollToken &+= 1
            }
        case .jump:
            guard let index = resolvedKeyboardCueIndex() else { return }
            jumpToCue(index: index)
        }
    }

    private func resolvedKeyboardCueIndex() -> Int? {
        let index = DigestKeyboardFocus.resolved(
            focused: focusedCueIndex,
            visible: visibleBookIndices,
            playing: activeCueIndex
        )
        if let index {
            focusedCueIndex = index
        }
        return index
    }

    private func stepSearch(_ delta: Int) {
        guard let next = DigestTranscriptSearch.step(
            current: searchHits.isEmpty ? nil : searchActive,
            count: searchHits.count,
            delta: delta
        ) else { return }
        searchActive = next
        searchScrollToken &+= 1
    }

    private func seekFromTOC(_ time: Double) {
        jumpAndPlay(time)
        tocExpanded = false
    }

    @ViewBuilder
    private func bookCueRow(index: Int) -> some View {
        let cue = displayCues[index]
        let isCurrent = activeCueIndex == index
        let isHit = searchHits.contains(index)
        let isActiveHit = searchHits.indices.contains(searchActive) && searchHits[searchActive] == index
        DigestCueRow(
            timeLabel: formatTime(cue.startTime),
            cueText: cue.text,
            timeColumnWidth: timeColumnWidth,
            isCurrent: isCurrent,
            query: searchQuery,
            onSeek: { jumpToCue(index: index) }
        )
        .help("跳到这句")
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, DigestCueDisplay.rowVerticalPadding)
        .background {
            if isActiveHit {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OpenMyChrome.warning.opacity(0.22))
            } else if isHit {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OpenMyChrome.warning.opacity(0.1))
            } else if isCurrent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
            } else if focusedCueIndex == index {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OpenMyChrome.rowSelected)
            }
        }
        .id(index)
    }

    /// 点歌词条目：先按目标索引刷新高亮/滚动，再交给播放器 seek。
    private func jumpToCue(index: Int) {
        guard displayCues.indices.contains(index) else { return }
        let cue = displayCues[index]
        activeCueIndex = index
        // 用户主动点句：立即跟随，不要被「手动滚动暂停」挡住。
        autoFollowSuspendedUntil = .distantPast
        resumeFollowTask?.cancel()
        resumeFollowTask = nil
        followScrollToken &+= 1
        jumpAndPlay(cue.startTime)
    }

    private func sidePaneEmptyState(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshActiveCue(at time: Double) {
        let previousTime = lastTrackedTime
        lastTrackedTime = time
        let isSeekJump = previousTime.isFinite && abs(time - previousTime) > seekJumpThreshold

        let resolved = Self.cueIndex(at: time, in: displayCues, hint: activeCueIndex)
        if resolved != activeCueIndex {
            activeCueIndex = resolved
        }

        // 非连续跳转（进度条/歌词点句/章节 seek）：立即恢复跟随并滚到目标句。
        // 连续播放的小步推进仍尊重「手动滚动后暂停 4 秒」。
        if isSeekJump {
            autoFollowSuspendedUntil = .distantPast
            resumeFollowTask?.cancel()
            resumeFollowTask = nil
            if resolved != nil {
                followScrollToken &+= 1
            }
        }
    }

    private func scrollToCue(_ index: Int, proxy: ScrollViewProxy) {
        ignoreLiveScrollUntil = Date().addingTimeInterval(0.45)
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private func noteUserScroll() {
        guard Date() >= ignoreLiveScrollUntil else { return }
        autoFollowSuspendedUntil = Date().addingTimeInterval(autoFollowResumeDelay)
        resumeFollowTask?.cancel()
        let delay = autoFollowResumeDelay
        resumeFollowTask = Task {
            let nanos = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard Date() >= autoFollowSuspendedUntil, activeCueIndex != nil else { return }
                followScrollToken &+= 1
            }
        }
    }

    /// 当前句判定：优先用 hint 邻域 O(1)，否则二分 O(log n)。
    private static func cueIndex(at time: Double, in cues: [VideoSubtitleCue], hint: Int?) -> Int? {
        guard !cues.isEmpty, time.isFinite else { return nil }

        if let hint, cues.indices.contains(hint) {
            if cues[hint].startTime <= time, time < cues[hint].endTime {
                var last = hint
                while last + 1 < cues.count,
                      cues[last + 1].startTime <= time,
                      time < cues[last + 1].endTime {
                    last += 1
                }
                return last
            }
            if hint + 1 < cues.count,
               cues[hint + 1].startTime <= time,
               time < cues[hint + 1].endTime {
                return hint + 1
            }
            if hint > 0,
               cues[hint - 1].startTime <= time,
               time < cues[hint - 1].endTime {
                return hint - 1
            }
        }

        var low = 0
        var high = cues.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].startTime <= time {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let candidate else { return nil }
        let cue = cues[candidate]
        return time < cue.endTime ? candidate : nil
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}

/// 监听侧栏列表的用户滚动，用于暂停自动跟随。
private struct SidePaneScrollActivityMonitor: NSViewRepresentable {
    let onUserScroll: () -> Void

    final class Coordinator {
        var onUserScroll: () -> Void
        private var token: NSObjectProtocol?
        private weak var scrollView: NSScrollView?

        init(onUserScroll: @escaping () -> Void) {
            self.onUserScroll = onUserScroll
        }

        func attach(to scrollView: NSScrollView) {
            if self.scrollView === scrollView, token != nil { return }
            detach()
            self.scrollView = scrollView
            token = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.onUserScroll()
            }
        }

        func detach() {
            if let token {
                NotificationCenter.default.removeObserver(token)
                self.token = nil
            }
            scrollView = nil
        }

        deinit {
            detach()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserScroll: onUserScroll)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
        DispatchQueue.main.async {
            guard let scrollView = nsView.enclosingScrollView else { return }
            context.coordinator.attach(to: scrollView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

private struct DropAndAddBar: View {
    @Binding var urlText: String
    @Binding var isDropTarget: Bool
    var isURLFieldFocused: FocusState<Bool>.Binding
    let submit: () -> Void
    let receiveProviders: ([NSItemProvider]) -> Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("添加链接…", text: $urlText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier(PlaybackWindowFocusController.urlFieldAccessibilityID)
                .frame(minWidth: 0, maxWidth: .infinity)
                .focused(isURLFieldFocused)
                .onSubmit(submit)
                .onExitCommand(perform: removeFocus)
            if !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: submit) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                .watchGlassButton(prominent: true)
                .controlSize(.small)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        .watchGlass(
            .clear,
            tint: isLinkDropTarget ? OpenMyChrome.raise : OpenMyChrome.canvas,
            in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                .strokeBorder(urlFieldStroke, lineWidth: isURLFieldFocused.wrappedValue ? 2 : 1)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: URLBarFramePreferenceKey.self,
                    value: geometry.frame(in: .named("seesee-window"))
                )
            }
        }
        .onDrop(of: [UTType.url, UTType.fileURL, UTType.plainText], isTargeted: $isDropTarget, perform: receiveProviders)
    }

    /// 拖着看板卡片经过时不亮，卡片不是链接。
    private var isLinkDropTarget: Bool {
        isDropTarget && !BoardDragPayload.isDraggingCard
    }

    private var urlFieldStroke: Color {
        if isURLFieldFocused.wrappedValue {
            return OpenMyChrome.ink
        }
        if isLinkDropTarget {
            return OpenMyChrome.ink.opacity(0.35)
        }
        return OpenMyChrome.fieldBorder
    }

    private func removeFocus() {
        isURLFieldFocused.wrappedValue = false
        PlaybackWindowFocusController.resign(in: NSApp.keyWindow)
    }
}

private struct EmptyLibraryView: View {
    @Binding var isDropTarget: Bool
    let receiveProviders: ([NSItemProvider]) -> Bool

    var body: some View {
        ZStack {
            DetailBackdrop(thumbnailURL: nil)

            VStack(spacing: 14) {
                Image(systemName: isDropTarget ? "arrow.down" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isDropTarget ? OpenMyChrome.canvas : OpenMyChrome.ink)
                    .frame(width: 70, height: 70)
                    .watchGlass(
                        .regular,
                        tint: isDropTarget ? OpenMyChrome.ink : OpenMyChrome.raise,
                        in: Circle()
                    )
                Text(isDropTarget ? "松手存入队列" : "随时可以开始")
                    .font(.title2.weight(.semibold))
                Text("复制视频链接后按 ⌘V。seesee 会下载一份干净的离线副本，并记住你看到哪儿。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .padding(36)
            .watchGlass(.clear, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .onDrop(of: [UTType.url, UTType.fileURL, UTType.plainText], isTargeted: $isDropTarget, perform: receiveProviders)
    }
}

extension Notification.Name {
    /// 左侧栏显隐：userInfo["collapsed"] 为 Bool 时设成指定态，缺省时切换。
    static let seeseeSidebarToggle = Notification.Name("SeeseeSidebarToggle")
}
