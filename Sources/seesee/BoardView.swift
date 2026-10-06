import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 看板视图的尺寸，取自 Paper「seesee 待播清单看板」的看板视图和卡片状态画板。
enum BoardMetrics {
    static let columnWidth: CGFloat = 247
    static let columnSpacing: CGFloat = 12
    static let boardHorizontalPadding: CGFloat = 16
    static let boardTopPadding: CGFloat = 12
    static let cardSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 8
    static let thumbnailHeight: CGFloat = 129
    static let ringDiameter: CGFloat = 32
    static let watchedOpacity: Double = 0.72
    static let archivedOpacity: Double = 0.55
    /// 顶栏标题的左边：红绿灯 20 起、宽 62，再空 20。
    static let topBarLeadingPadding: CGFloat = 102
    static let addFieldWidth: CGFloat = 300
}

/// 看板右侧播放器面板开没开。Esc 由 AppDelegate 统一接，退出全屏之后再来问这里。
@MainActor
final class BoardPlayerPanelState: ObservableObject {
    static let shared = BoardPlayerPanelState()

    @Published var isPresented = false

    /// 看板视图里面板开着就收起，返回 true 表示 Esc 用掉了。
    func collapse() -> Bool {
        guard isPresented, LibraryViewMode.stored() == .board else { return false }
        withAnimation(BoardPlayerPanelState.animation) {
            isPresented = false
        }
        return true
    }

    static var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : .easeInOut(duration: 0.22)
    }
}

extension BoardDragPayload {
    /// 正在拖的是不是看板卡片。拖动中系统拖动剪贴板里是这一次拖动的内容，只读类型不读内容，不用等。
    static var isDraggingCard: Bool {
        NSPasteboard(name: .drag).types?.contains(NSPasteboard.PasteboardType(typeIdentifier)) == true
    }

    static func isCardDrop(_ providers: [NSItemProvider]) -> Bool {
        providers.contains(where: isCard) || isDraggingCard
    }
}

// MARK: - 顶栏

/// 列表视图和看板视图的切换钮，放在顶栏右上角、齿轮左边。
struct LibraryViewModeToggle: View {
    @Binding var mode: LibraryViewMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.list)
            segment(.board)
        }
        .padding(2)
        .background(OpenMyChrome.raise, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous)
                .strokeBorder(OpenMyChrome.hair)
        }
    }

    private func segment(_ target: LibraryViewMode) -> some View {
        let selected = mode == target
        return Button {
            mode = target
        } label: {
            ViewModeIcon(mode: target)
                .stroke(selected ? OpenMyChrome.ink : OpenMyChrome.muted, style: StrokeStyle(
                    lineWidth: target == .list ? 1.5 : 1.3,
                    lineCap: .round,
                    lineJoin: .round
                ))
                .frame(width: 14, height: 14)
                .frame(width: 28, height: 22)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(BoardChrome.segmentSelected)
                            .shadow(color: BoardChrome.segmentShadow, radius: 1, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(target.title)（⌘\(target.shortcutKey)）")
        .accessibilityLabel(target.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 14×14 的视图图标：列表是三条横线，看板是三根高低不同的柱子。
private struct ViewModeIcon: Shape {
    let mode: LibraryViewMode

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 14
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        switch mode {
        case .list:
            for y in [3.5, 7.0, 10.5] as [CGFloat] {
                path.move(to: point(2, y))
                path.addLine(to: point(12, y))
            }
        case .board:
            for (x, height) in [(1.5, 10.0), (5.5, 7.0), (9.5, 8.5)] as [(CGFloat, CGFloat)] {
                path.addRoundedRect(
                    in: CGRect(origin: point(x, 2), size: CGSize(width: 3 * scale, height: height * scale)),
                    cornerSize: CGSize(width: scale, height: scale)
                )
            }
        }
        return path
    }
}

/// 看板视图的顶栏：标题和条数、添加链接、视图切换、齿轮。
struct BoardTopBar<AddField: View>: View {
    let itemCount: Int
    @Binding var mode: LibraryViewMode
    @ViewBuilder var addField: AddField

    var body: some View {
        HStack(spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("待播清单")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OpenMyChrome.ink)
                Text("\(itemCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OpenMyChrome.faint)
            }
            .fixedSize()

            addField
                .frame(width: BoardMetrics.addFieldWidth)

            Spacer(minLength: 12)

            HStack(spacing: PaneHeaderIconMetrics.spacing) {
                TitlebarInteractiveHost {
                    LibraryViewModeToggle(mode: $mode)
                }
                .fixedSize()

                TitlebarInteractiveHost(tooltip: DigestSettingsCopy.gearTitle) {
                    Button {
                        DigestSettingsOpener.open()
                    } label: {
                        PaneHeaderIconLabel(systemImage: "gearshape", title: DigestSettingsCopy.gearTitle)
                    }
                    .watchGlassButton()
                    .accessibilityLabel(DigestSettingsCopy.gearTitle)
                }
                .fixedSize()
            }
        }
        .padding(.leading, BoardMetrics.topBarLeadingPadding)
        .padding(.trailing, 14)
        .frame(height: OpenMyChrome.paneHeaderHeight)
    }
}

// MARK: - 列

/// 一列：列头加一串卡片，卡片可以拖到别的列。
struct BoardColumnView<Card: View, Trailing: View>: View {
    let column: BoardColumn
    let itemIDs: [UUID]
    let onDropItem: (UUID) -> Bool
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var card: (UUID) -> Card
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: BoardMetrics.cardSpacing) {
            header
            ScrollView(.vertical) {
                LazyVStack(spacing: BoardMetrics.cardSpacing) {
                    ForEach(itemIDs, id: \.self) { id in
                        card(id)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .frame(width: BoardMetrics.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                .fill(isDropTarget ? OpenMyChrome.rowHover : Color.clear)
                .padding(-4)
        }
        .onDrop(of: [UTType.plainText], isTargeted: $isDropTarget) { providers in
            receive(providers)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.title) \(itemIDs.count) 条")
    }

    private var header: some View {
        HStack(spacing: 7) {
            BoardColumnIcon(column: column)
                .frame(width: 14, height: 14)
            Text(column.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(column == .archived ? OpenMyChrome.muted : OpenMyChrome.ink)
            Text("\(itemIDs.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(OpenMyChrome.faint)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .padding(.horizontal, 4)
        .frame(height: 28)
    }

    /// 只收看板卡片。别处拖来的链接和文字返回 false，列不做接受的样子。
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard BoardDragPayload.isCardDrop(providers),
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = BoardDragPayload.itemID(from: text) else { return }
            DispatchQueue.main.async { _ = onDropItem(id) }
        }
        return true
    }
}

/// 列头图标，14×14，按 Paper 画法：收件箱虚线圈、待看空圈、观看中半实心、已看完实心带勾、已归档盒子。
private struct BoardColumnIcon: View {
    let column: BoardColumn

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 14
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }
            func circle(radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(
                    x: (7 - radius) * scale,
                    y: (7 - radius) * scale,
                    width: radius * 2 * scale,
                    height: radius * 2 * scale
                ))
            }
            switch column {
            case .inbox:
                context.stroke(
                    circle(radius: 5.6),
                    with: .color(OpenMyChrome.muted),
                    style: StrokeStyle(lineWidth: 1.4 * scale, dash: [2.2 * scale, 1.8 * scale])
                )
            case .toWatch:
                context.stroke(circle(radius: 5.6), with: .color(OpenMyChrome.muted), lineWidth: 1.4 * scale)
            case .watching:
                context.stroke(circle(radius: 5.6), with: .color(OpenMyChrome.ink), lineWidth: 1.4 * scale)
                var half = Path()
                half.move(to: point(7, 3.4))
                half.addArc(
                    center: point(7, 7),
                    radius: 3.6 * scale,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(90),
                    clockwise: false
                )
                half.closeSubpath()
                context.fill(half, with: .color(OpenMyChrome.ink))
            case .watched:
                context.fill(circle(radius: 6.2), with: .color(OpenMyChrome.muted))
                var check = Path()
                check.move(to: point(4.4, 7.2))
                check.addLine(to: point(6.2, 9))
                check.addLine(to: point(9.6, 5.4))
                context.stroke(
                    check,
                    with: .color(OpenMyChrome.canvas),
                    style: StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, lineJoin: .round)
                )
            case .archived:
                let lid = Path(roundedRect: CGRect(x: 1.8 * scale, y: 2.6 * scale, width: 10.4 * scale, height: 3 * scale), cornerRadius: scale)
                var box = Path()
                box.move(to: point(2.8, 5.6))
                box.addLine(to: point(2.8, 10.8))
                box.addQuadCurve(to: point(3.8, 11.8), control: point(2.8, 11.8))
                box.addLine(to: point(10.2, 11.8))
                box.addQuadCurve(to: point(11.2, 10.8), control: point(11.2, 11.8))
                box.addLine(to: point(11.2, 5.6))
                box.move(to: point(5.6, 8))
                box.addLine(to: point(8.4, 8))
                let style = StrokeStyle(lineWidth: 1.3 * scale, lineCap: .round, lineJoin: .round)
                context.stroke(lid, with: .color(OpenMyChrome.faint), style: style)
                context.stroke(box, with: .color(OpenMyChrome.faint), style: style)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 列头右侧的小按钮：收件箱的「+」、已看完的「归档 N 条」。
struct BoardColumnHeaderButton: View {
    enum Kind {
        case add
        case archive(count: Int)
    }

    let kind: Kind
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            switch kind {
            case .add:
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovering ? OpenMyChrome.ink : OpenMyChrome.faint)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            case .archive(let count):
                Text("归档 \(count) 条")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(isHovering ? OpenMyChrome.ink : OpenMyChrome.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(OpenMyChrome.fieldBorder)
                    }
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        switch kind {
        case .add: return "添加链接"
        case .archive(let count): return "把看完满 \(BoardColumn.archiveSuggestionDays) 天的 \(count) 条挪到已归档"
        }
    }
}

// MARK: - 卡片

/// 看板卡片：缩略图、主标题、原标题（小一号灰字）、频道、时长、观看进度。
/// 正常状态不显示状态文字，只有等待下载、下载中、预览可播、下载失败、观看进度才显示。
struct BoardCard: View, Equatable {
    let item: WatchItem
    let column: BoardColumn
    let isSelected: Bool
    let isPreviewPlayable: Bool
    let open: () -> Void
    /// 无障碍「挪到某列」动作；和拖放走同一条路。
    let moveTo: (BoardColumn) -> Void
    let availableColumns: [BoardColumn]
    @State private var isHovering = false

    static func == (lhs: BoardCard, rhs: BoardCard) -> Bool {
        lhs.item == rhs.item
            && lhs.column == rhs.column
            && lhs.isSelected == rhs.isSelected
            && lhs.isPreviewPlayable == rhs.isPreviewPlayable
            && lhs.availableColumns == rhs.availableColumns
    }

    var body: some View {
        let display = DownloadProgressMemory.display(for: item, isPreviewPlayable: isPreviewPlayable)
        let status = BoardCardStatusText.value(
            isFailed: item.state == .failed,
            downloadRowText: display.rowText,
            watchedFraction: watchedFraction
        )
        // 不用 Button：macOS 上 Button 按下就接管鼠标，onDrag 拖不起来。点按用 onTapGesture，
        // 读屏和键盘照旧当按钮用（默认动作、按钮特征、全键盘操作时可聚焦）。
        VStack(alignment: .leading, spacing: BoardMetrics.cardSpacing) {
            BoardCardThumbnail(item: item, display: display)
            BoardCardText(item: item, status: status)
        }
        .padding(BoardMetrics.cardPadding)
        .modifier(BoardCardChrome(isSelected: isSelected, isHovering: isHovering))
        .contentShape(RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous))
        .opacity(cardOpacity)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        // 缩略图不当成图片读，读标题，值是频道和状态文字。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.boardTitle)
        .accessibilityValue(BoardCardAccessibility.value(channel: item.boardChannel, status: status))
        .modifier(BoardCardKeyboardAccess(open: open))
        .onDrag {
            BoardDragPayload.provider(for: item.id)
        } preview: {
            BoardCardDragPreview(item: item, display: display, status: status)
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, open)
        .modifier(BoardCardMoveActions(current: column, columns: availableColumns, moveTo: moveTo))
    }

    private var cardOpacity: Double {
        guard !isSelected else { return 1 }
        switch column {
        case .watched: return BoardMetrics.watchedOpacity
        case .archived: return BoardMetrics.archivedOpacity
        default: return 1
        }
    }

    private var watchedFraction: Double? {
        guard !item.isWatched, let duration = item.duration, duration > 0, item.resumablePosition > 0 else {
            return nil
        }
        return item.resumablePosition / duration
    }
}

private struct BoardCardText: View {
    let item: WatchItem
    let status: BoardCardStatusText.Value?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let title = item.titleDisplay
            Text(item.boardTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OpenMyChrome.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minHeight: 18)
            // 有译名或改过名时，下面一行是原标题：小一号灰字，和列表行同一个规则。
            if let secondary = title.secondary {
                Text(secondary)
                    .font(.system(size: 12))
                    .foregroundStyle(OpenMyChrome.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minHeight: 16)
            }

            HStack(spacing: 5) {
                SourceBrandMark(sourceName: item.sourceName)
                Text(item.boardChannel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OpenMyChrome.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let status {
                    Text(status.text)
                        .font(.system(
                            size: 11,
                            weight: .medium,
                            design: status.isPercentOnly ? .monospaced : .default
                        ))
                        .monospacedDigit()
                        .foregroundStyle(status.isFailure ? OpenMyChrome.rec : OpenMyChrome.muted)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .padding(.top, 4)
            .frame(minHeight: 18)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 卡片缩略图：229×129，圆角 10。时长角标、观看进度白线、下载圆环（32）都画在上面。
struct BoardCardThumbnail: View {
    let item: WatchItem
    let display: DownloadProgressDisplay.Model
    /// 窗口当前的外观。缩略图整体按深色取色，只有还没封面时的底跟着窗口走（Paper 浅色卡片是浅灰底）。
    @Environment(\.colorScheme) private var windowScheme

    var body: some View {
        ZStack {
            if let image = ThumbnailImageCache.image(for: item.thumbnailFileURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ZStack {
                    LinearGradient(
                        colors: windowScheme == .dark
                            ? [OpenMyChrome.raise, OpenMyChrome.canvas]
                            : [OpenMyChrome.rowHover, OpenMyChrome.rowSelected],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    if !display.showsRing {
                        placeholderIcon
                    }
                }
                .environment(\.colorScheme, windowScheme)
            }

            if display.showsRing {
                DownloadThumbnailOverlay(display: display, diameter: BoardMetrics.ringDiameter)
            } else if item.state == .queued {
                // 排队时没有传输发生，只压暗，不转圈；和队列行的规则一致。
                Color.black.opacity(0.22)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: BoardMetrics.thumbnailHeight)
        .overlay(alignment: .bottomTrailing) {
            if let duration = item.duration, item.state == .ready {
                Text(BoardCardThumbnail.formatDuration(duration))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.trailing, 6)
                    .padding(.bottom, 8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // 观看进度线固定白色：画在视频画面上，不随深浅外观变。
            if let duration = item.duration, duration > 0, item.resumablePosition > 0 {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white)
                        .frame(width: geometry.size.width * min(item.resumablePosition / duration, 1), height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: OpenMyChrome.radiusMd, style: .continuous))
        // 缩略图区域是画面，里面的角标和圆环一律按深色取色。
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var placeholderIcon: some View {
        if item.state == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(windowScheme == .dark ? OpenMyChrome.ink.opacity(0.55) : OpenMyChrome.faint)
        } else {
            Image(systemName: placeholderSymbol)
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(OpenMyChrome.ink)
        }
    }

    private var placeholderSymbol: String {
        switch item.state {
        case .queued: return "clock.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .ready: return item.isWatched ? "checkmark.circle.fill" : "play.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}

/// 卡片底色：正常是卡片色，悬停亮一档，选中（正在右侧播放）用选中色和亮一档的边。
/// 卡片底色和描边：选中、悬停、平时三档。
private struct BoardCardChrome: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                    .fill(fill)
                    .shadow(color: BoardChrome.cardShadow, radius: 1, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                    .strokeBorder(isSelected ? OpenMyChrome.rowSelectedStroke : OpenMyChrome.hair)
            }
    }

    private var fill: Color {
        if isSelected { return OpenMyChrome.rowSelected }
        if isHovering { return BoardChrome.cardHover }
        return BoardChrome.card
    }
}

/// 打开系统「全键盘操作」时卡片能用 Tab 聚焦，回车或空格打开，和按钮一样；点按不会让卡片带上聚焦框。
/// macOS 13 没有这两个接口，只靠读屏的默认动作。
private struct BoardCardKeyboardAccess: ViewModifier {
    let open: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .focusable(interactions: .activate)
                .onKeyPress(.return) {
                    open()
                    return .handled
                }
                .onKeyPress(.space) {
                    open()
                    return .handled
                }
        } else {
            content
        }
    }
}

/// 拖动中的卡片：抬起一层、斜 2 度、带阴影。
private struct BoardCardDragPreview: View {
    let item: WatchItem
    let display: DownloadProgressDisplay.Model
    let status: BoardCardStatusText.Value?

    var body: some View {
        VStack(alignment: .leading, spacing: BoardMetrics.cardSpacing) {
            BoardCardThumbnail(item: item, display: display)
            BoardCardText(item: item, status: status)
        }
        .padding(BoardMetrics.cardPadding)
        .frame(width: BoardMetrics.columnWidth)
        .background(OpenMyChrome.raise, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusLg, style: .continuous)
                .strokeBorder(OpenMyChrome.rowSelectedStroke)
        }
        .rotationEffect(.degrees(2))
        .shadow(color: BoardChrome.dragShadow, radius: 16, y: 12)
        .padding(24)
    }
}

/// 无障碍动作「挪到收件箱」等：拖不了的时候（读屏、键盘）也能改状态。
private struct BoardCardMoveActions: ViewModifier {
    let current: BoardColumn
    let columns: [BoardColumn]
    let moveTo: (BoardColumn) -> Void

    func body(content: Content) -> some View {
        // 后加的动作排在前面，倒过来包，读屏读到的顺序才和看板从左到右一致。
        columns
            .filter { $0 != current }
            .reversed()
            .reduce(AnyView(content)) { view, column in
                AnyView(view.accessibilityAction(named: Text("挪到\(column.title)")) { moveTo(column) })
            }
    }
}

// MARK: - 播放器面板

/// 看板右侧滑出的播放器面板：左边缘可拖动改宽度，宽度记在偏好设置里。
struct BoardPlayerPanel<Content: View>: View {
    @Binding var width: Double
    let windowWidth: CGFloat
    @ViewBuilder var content: Content
    @State private var dragStartWidth: Double?

    var body: some View {
        let shownWidth = BoardPlayerPanelMetrics.clampedWidth(width, windowWidth: Double(windowWidth))
        content
            .frame(width: CGFloat(shownWidth))
            .frame(maxHeight: .infinity)
            .background(OpenMyChrome.canvas)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(OpenMyChrome.fieldBorder)
                    .frame(width: 1)
            }
            .overlay(alignment: .leading) {
                resizeHandle(shownWidth: shownWidth)
            }
            .shadow(color: BoardChrome.panelShadow, radius: 16, x: -12)
    }

    private func resizeHandle(shownWidth: Double) -> some View {
        PanelResizeHandle(
            onBegan: { dragStartWidth = shownWidth },
            onChanged: { translation in
                let start = dragStartWidth ?? shownWidth
                width = BoardPlayerPanelMetrics.clampedWidth(
                    start - Double(translation),
                    windowWidth: Double(windowWidth)
                )
            },
            onEnded: { dragStartWidth = nil }
        )
        .frame(width: 8)
        .offset(x: -4)
        .accessibilityHidden(true)
    }
}

/// 面板左边缘的拖动条，用 AppKit 视图做，和 NSSplitView 的分隔条一样：
/// 光标由光标区域和光标更新事件管，进出自动切换，不用 NSCursor 压栈出栈，面板收起时跟着视图一起消失；
/// 按下和拖动也由这个视图自己接，它是指针下最上层的视图，光标不会被下面的播放器或看板改掉。
private struct PanelResizeHandle: NSViewRepresentable {
    let onBegan: () -> Void
    /// 按下以后指针在水平方向移动了多少点，向右为正。
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> HandleView {
        HandleView()
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.onBegan = onBegan
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }

    final class HandleView: NSView {
        var onBegan: () -> Void = {}
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: () -> Void = {}
        private var startX: CGFloat?
        private var cursorArea: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let cursorArea { removeTrackingArea(cursorArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            cursorArea = area
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            onBegan()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            onChanged(event.locationInWindow.x - startX)
        }

        override func mouseUp(with event: NSEvent) {
            guard startX != nil else { return }
            startX = nil
            onEnded()
        }
    }
}

// MARK: - 看板专用颜色

/// 看板新加的颜色，深浅两值，按所在视图的外观取色。其余颜色直接用 OpenMyChrome。
enum BoardChrome {
    /// 卡片底色：深色是行悬停色 #181818，浅色是白卡 #FFFFFF（Paper --color-light-card）。
    static let card = Color(nsColor: NSColor(dark: OpenMyChrome.rowHoverHex, light: 0xFFFFFF))
    /// 悬停亮（浅色下暗）一档：深色 raise #1E1E1E，浅色行悬停色 #F2F2F3。
    static let cardHover = Color(nsColor: NSColor(dark: OpenMyChrome.raiseHex, light: OpenMyChrome.lightRowHoverHex))
    /// 视图切换选中的那一格：深色按下色 #333333，浅色白底加阴影（Paper 看板视图 浅色）。
    static let segmentSelected = Color(nsColor: NSColor(dark: OpenMyChrome.rowPressedHex, light: 0xFFFFFF))
    /// 卡片阴影：深色不要，浅色 #1A1A1F 6%（Paper 卡片 0 1px 2px）。
    static let cardShadow = shadow(darkAlpha: 0, lightAlpha: 0.06)
    /// 选中格阴影：深色不要，浅色 #1A1A1F 12%。
    static let segmentShadow = shadow(darkAlpha: 0, lightAlpha: 0.12)
    /// 播放器面板和拖动中卡片的投影：深色压在黑底上要重，浅色底上减轻。
    static let panelShadow = shadow(darkAlpha: 0.6, lightAlpha: 0.12)
    static let dragShadow = shadow(darkAlpha: 0.55, lightAlpha: 0.18)

    private static func shadow(darkAlpha: CGFloat, lightAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor.black.withAlphaComponent(darkAlpha)
                : NSColor(hex: OpenMyChrome.lightInkHex).withAlphaComponent(lightAlpha)
        })
    }
}
