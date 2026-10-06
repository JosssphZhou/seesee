import AppKit
import SwiftUI

/// 侧栏队列的几何约定：添加栏占标题栏区域，列表从栏下开始，不再叠加系统标题栏内边距。
enum SidebarQueueLayout {
    static let addBarHeight: CGFloat = OpenMyChrome.paneHeaderHeight
    static let dividerHeight: CGFloat = 1
    static let listTopPadding: CGFloat = 8
    static let listBottomPadding: CGFloat = 12
    static let listHorizontalPadding: CGFloat = 9
    static let rowSpacing: CGFloat = 4
    static let queueTopAnchorID = "queue-top"

    /// 添加栏加分隔线的下沿。再往下才是列表，含 8 点顶垫。
    static var addBarBottomY: CGFloat {
        addBarHeight + dividerHeight
    }

    /// 首行画面起点：添加栏下沿加 8 点顶垫。queue-top 锚点不计入行距。
    static var listOriginY: CGFloat {
        addBarBottomY + listTopPadding
    }

    /// 从窗口顶部往下的纵坐标映射到队列行。
    /// 添加栏内返回 nil。顶垫属于第 1 行的宽容命中（点击意图即第 1 行）。
    static func rowIndex(atWindowY y: CGFloat, rowHeight: CGFloat, rowCount: Int) -> Int? {
        guard rowHeight > 0, rowCount > 0 else { return nil }
        let yInList = y - addBarBottomY
        guard yInList >= 0 else { return nil }
        if yInList < listTopPadding {
            return 0
        }
        let yInRows = yInList - listTopPadding
        let stride = rowHeight + rowSpacing
        let index = Int(yInRows / stride)
        guard index >= 0, index < rowCount else { return nil }
        let offsetInRow = yInRows - CGFloat(index) * stride
        guard offsetInRow < rowHeight else { return nil }
        return index
    }

    /// 滚动锚点放在 LazyVStack 外面，零高占位不得再吃一行行距。
    /// 8 点顶垫由首行按钮自己带上，这样顶垫既是画面边距也是第 1 行命中区。
    struct ScrollStack<Content: View>: View {
        @ViewBuilder var content: Content

        var body: some View {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .id(queueTopAnchorID)
                content
                    .padding(.horizontal, listHorizontalPadding)
                    .padding(.bottom, listBottomPadding)
            }
        }
    }

    /// 放进首行按钮内部，让 8 点顶垫可点。
    struct FirstRowTopGutter: View {
        var body: some View {
            Color.clear
                .frame(height: listTopPadding)
        }
    }
}

/// 嵌套宿主上报零安全区，避免队列 ScrollView 再继承标题栏 contentInsets。
/// 该内边距会把画面下推，而 SwiftUI 按钮命中仍停在未内缩的坐标。
final class SidebarQueueHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

struct SidebarQueueSafeAreaHost<Content: View>: NSViewRepresentable {
    var content: Content

    func makeNSView(context: Context) -> SidebarQueueHostingView<Content> {
        let view = SidebarQueueHostingView(rootView: content)
        // 嵌套 NSHostingView 不继承外层 WindowGroup 的配色，须在这一层补回。
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: SidebarQueueHostingView<Content>, context: Context) {
        view.rootView = content
    }
}

struct SidebarQueueChrome<Header: View, Content: View>: View {
    var header: Header
    var content: Content

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            OpenMyChrome.canvas
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .frame(height: SidebarQueueLayout.addBarHeight)

                Divider()

                SidebarQueueSafeAreaHost(
                    content: content
                        .preferredColorScheme(.dark)
                        .tint(OpenMyChrome.ink)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}
