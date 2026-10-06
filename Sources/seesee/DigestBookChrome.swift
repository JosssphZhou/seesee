import AppKit
import Combine
import SwiftUI

enum DigestBookChrome {
    static let minColumnWidth: CGFloat = 232
    static let minActionHit: CGFloat = 22
    static let highlightMarkWidth: CGFloat = 2
    static let highlightTitle = "划线"
    static let unhighlightTitle = "取消划线"
    static let commentBarLabel = "批语"
    static let commentPlaceholder = "写一句批语"
    static let commentHintIdle = "回车保存 · Esc 只留划线"
    static let commentHintTyping = "回车保存"
    static let commentFieldHeight: CGFloat = 28
    static let commentFieldPadding: CGFloat = 10
    static let commentFieldSpacing: CGFloat = 6
    static let commentSavedSize: CGFloat = 11
    static let commentHintSize: CGFloat = 10
    static let commentHintSpacing: CGFloat = 10
    static let toolbarSpacing: CGFloat = 8
    static let headerHorizontalPadding: CGFloat = 12
    /// 悬停时给右上角「取消划线」按钮让出的宽度：按钮 64 点加 2 点余量。
    static let actionReserveWidth: CGFloat = 66

    static func entryTitle(_ count: Int) -> String {
        "划线 \(count)"
    }
}

enum DigestCommentHintLayout {
    static func width(of text: String) -> CGFloat {
        ceil(
            (text as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: DigestBookChrome.commentHintSize)]
            ).width
        )
    }

    static func shouldShow(columnWidth: CGFloat, hint: String) -> Bool {
        let inner = columnWidth - DigestBookChrome.commentFieldPadding * 2
        return width(of: hint) + DigestBookChrome.commentHintSpacing <= inner + 0.5
    }
}



/// 划线插入批语行时锁住列表滚动原点，避免输入框抢焦点把上方句子带走。
final class DigestScrollLock: ObservableObject {
    private weak var scrollView: NSScrollView?
    private var boundsToken: NSObjectProtocol?
    private var liveScrollToken: NSObjectProtocol?
    private var frozenOrigin: NSPoint?
    private var isRestoring = false

    func attach(to scrollView: NSScrollView) {
        if self.scrollView === scrollView, boundsToken != nil { return }
        detach()
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsToken = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.restoreIfNeeded()
        }
        liveScrollToken = NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.followUserScroll()
        }
    }

    func freeze() {
        frozenOrigin = scrollView?.contentView.bounds.origin
    }

    func unfreeze() {
        frozenOrigin = nil
    }

    func restoreIfNeeded() {
        guard !isRestoring, let frozenOrigin, let scrollView else { return }
        let clip = scrollView.contentView
        if hypot(clip.bounds.origin.x - frozenOrigin.x, clip.bounds.origin.y - frozenOrigin.y) < 0.5 {
            return
        }
        isRestoring = true
        clip.scroll(to: frozenOrigin)
        scrollView.reflectScrolledClipView(clip)
        isRestoring = false
    }

    private func followUserScroll() {
        frozenOrigin = scrollView?.contentView.bounds.origin
    }

    func detach() {
        if let boundsToken {
            NotificationCenter.default.removeObserver(boundsToken)
            self.boundsToken = nil
        }
        if let liveScrollToken {
            NotificationCenter.default.removeObserver(liveScrollToken)
            self.liveScrollToken = nil
        }
        scrollView = nil
        frozenOrigin = nil
    }

    deinit {
        detach()
    }
}

struct DigestScrollLockMonitor: NSViewRepresentable {
    let lock: DigestScrollLock

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = nsView.enclosingScrollView else { return }
            lock.attach(to: scrollView)
        }
    }
}

enum DigestHoverTracking {
    static let options: NSTrackingArea.Options = [
        .mouseEnteredAndExited,
        .activeAlways,
        .inVisibleRect
    ]
}

final class DigestHoverProbeView: NSView {
    var onHover: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: DigestHoverTracking.options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct DigestHoverMonitor: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> DigestHoverProbeView {
        let view = DigestHoverProbeView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: DigestHoverProbeView, context: Context) {
        nsView.onHover = onHover
    }
}

enum DigestBookHitKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

enum DigestBookWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
