import AppKit
import SwiftUI

struct DigestCueRow: View {
    let timeLabel: String
    let cueText: String
    let timeColumnWidth: CGFloat
    var isCurrent = false
    var query = ""
    var onSeek: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            timeButton
            cueTextBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeButton: some View {
        Button(action: onSeek) {
            Text(timeLabel)
                .font(.system(size: DigestCueDisplay.originalSize).monospacedDigit())
                .foregroundStyle(isCurrent ? OpenMyChrome.ink : OpenMyChrome.muted)
                .frame(width: timeColumnWidth, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .alignmentGuide(.firstTextBaseline) { dimensions in
            dimensions[.top] + DigestCueDisplay.timeBaselineFromTop
        }
    }

    private var cueTextBlock: some View {
        DigestCueText(
            text: cueText,
            query: query,
            isCurrent: isCurrent,
            onSeek: onSeek
        )
        .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.firstTextBaseline) { dimensions in
            dimensions[.top] + DigestCueDisplay.firstLineBaselineFromTop
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DigestBookHitKey.self,
                    value: ["cue-text": proxy.frame(in: .named("digest-book-page"))]
                )
            }
        )
    }
}

struct DigestCueText: NSViewRepresentable {
    var text: String
    var query: String
    var isCurrent: Bool
    var onSeek: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FittingTextView {
        let view = FittingTextView()
        view.isEditable = false
        view.isSelectable = false
        view.isRichText = true
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.focusRingType = .none
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.allowsUndo = false
        view.font = NSFont.systemFont(ofSize: DigestCueDisplay.originalSize)
        view.layoutManager?.usesFontLeading = false
        context.coordinator.parent = self
        view.onCollapsedClick = {
            context.coordinator.parent?.onSeek()
        }
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: FittingTextView, context: Context) {
        context.coordinator.parent = self
        view.onCollapsedClick = {
            context.coordinator.parent?.onSeek()
        }
        let snapshot = text + "\u{1e}" + query + "\u{1e}" + (isCurrent ? "1" : "0")
        if context.coordinator.renderedSnapshot != snapshot {
            apply(to: view, coordinator: context.coordinator)
            context.coordinator.renderedSnapshot = snapshot
            view.invalidateIntrinsicContentSize()
        }
    }

    /// 只量不改：SwiftUI 会拿各种试探宽度来问尺寸，改了文本视图的排版宽度，
    /// 最终放置时视图宽度没变就不会重新排版，句子就停在试探宽度上挤成窄列。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FittingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let height = DigestCueDisplay.blockHeight(for: text, width: width, isCurrent: isCurrent)
        return CGSize(width: width, height: height)
    }

    private func apply(to view: FittingTextView, coordinator: Coordinator) {
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        let attributed = DigestCueDisplay.attributedString(
            text: text,
            query: query,
            isCurrent: isCurrent,
            originalColor: OpenMyChrome.nsMuted,
            translationColor: OpenMyChrome.nsInk
        )
        view.textStorage?.setAttributedString(attributed)
        coordinator.renderedSnapshot = text + "\u{1e}" + query + "\u{1e}" + (isCurrent ? "1" : "0")
    }

    final class Coordinator {
        var parent: DigestCueText?
        var renderedSnapshot = ""
    }
}

final class FittingTextView: NSTextView {
    var onCollapsedClick: (() -> Void)?

    convenience init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        zeroInnerInsets()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        zeroInnerInsets()
    }

    private func zeroInnerInsets() {
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        layoutManager?.usesFontLeading = false
    }

    override var intrinsicContentSize: NSSize {
        guard let textContainer, let layoutManager else {
            return NSSize(width: NSView.noIntrinsicMetric, height: ceil(DigestCueDisplay.translationSize * DigestCueDisplay.translationLineMultiple))
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(ceil(used.height), ceil(DigestCueDisplay.translationSize * DigestCueDisplay.translationLineMultiple))
        )
    }

    override var firstBaselineOffsetFromTop: CGFloat {
        DigestCueDisplay.firstLineBaselineFromTop
    }

    override func layout() {
        super.layout()
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        if let textContainer, bounds.width > 0 {
            textContainer.size = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
        invalidateIntrinsicContentSize()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onCollapsedClick?()
    }
}
