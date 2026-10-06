import AppKit
import SwiftUI

struct DigestNoteTextStack: View {
    let text: String

    var body: some View {
        let lines = DigestCueDisplay.lines(from: text)
        VStack(alignment: .leading, spacing: DigestCueDisplay.pairSpacing) {
            Text(lines.translation)
                .font(.system(size: DigestCueDisplay.translationSize))
                .foregroundStyle(OpenMyChrome.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let original = lines.original {
                Text(original)
                    .font(.system(size: DigestCueDisplay.originalSize))
                    .foregroundStyle(OpenMyChrome.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DigestCueRow: View {
    let timeLabel: String
    let cueText: String
    let timeColumnWidth: CGFloat
    var isCurrent = false
    var query = ""
    var isHighlighted = false
    var showsActions = false
    var onSeek: () -> Void = {}
    var onHighlight: () -> Void = {}
    var highlightTitle = DigestBookChrome.highlightTitle
    var stacksActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                timeButton
                cueTextBlock
                    .padding(.trailing, showsActions && !stacksActions ? DigestBookChrome.actionReserveWidth : 0)
            }
            .overlay(alignment: .leading) {
                if isHighlighted {
                    HighlightSentenceMark()
                }
            }
            if showsActions && stacksActions {
                DigestCueActionButtons(
                    onHighlight: onHighlight,
                    highlightTitle: highlightTitle
                )
                .padding(.leading, timeColumnWidth + 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if showsActions && !stacksActions {
                DigestCueActionButtons(
                    onHighlight: onHighlight,
                    highlightTitle: highlightTitle
                )
            }
        }
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

private struct HighlightSentenceMark: View {
    var body: some View {
        GeometryReader { proxy in
            let page = proxy.frame(in: .named("digest-book-page"))
            let height = max(0, proxy.size.height - 4)
            let rect = CGRect(
                x: page.minX,
                y: page.minY + 2,
                width: DigestBookChrome.highlightMarkWidth,
                height: height
            )
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(OpenMyChrome.ink)
                .frame(width: DigestBookChrome.highlightMarkWidth, height: height)
                .offset(y: 2)
                .preference(
                    key: DigestBookHitKey.self,
                    value: ["highlight-mark": rect]
                )
        }
        .frame(width: DigestBookChrome.highlightMarkWidth)
    }
}

struct DigestCueActionButtons: View {
    var onHighlight: () -> Void
    var highlightTitle = DigestBookChrome.highlightTitle

    var body: some View {
        HStack(spacing: 4) {
            actionButton(title: highlightTitle, action: onHighlight, hitKey: "highlight-action")
        }
        .accessibilityElement(children: .contain)
    }

    private func actionButton(title: String, action: @escaping () -> Void, hitKey: String) -> some View {
        DigestAppKitActionButton(title: title, identifier: "digest.highlight", action: action)
            .padding(.horizontal, 8)
            .frame(minWidth: DigestBookChrome.minActionHit, minHeight: DigestBookChrome.minActionHit)
            .help(title)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DigestBookHitKey.self,
                        value: [hitKey: proxy.frame(in: .named("digest-book-page"))]
                    )
                }
            )
    }
}

private struct DigestAppKitActionButton: NSViewRepresentable {
    var title: String
    var identifier: String
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.click))
        button.isBordered = false
        button.bezelStyle = .inline
        button.setButtonType(.momentaryPushIn)
        button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = OpenMyChrome.nsInk
        button.focusRingType = .none
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityElement(true)
        button.setAccessibilityHidden(false)
        button.wantsLayer = true
        button.layer?.backgroundColor = OpenMyChrome.nsRaise.cgColor
        button.layer?.cornerRadius = OpenMyChrome.radiusSm
        button.layer?.borderWidth = 1
        button.layer?.borderColor = OpenMyChrome.nsHair.cgColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        if button.title != title {
            button.title = title
            button.setAccessibilityLabel(title)
        }
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityHidden(false)
        button.setAccessibilityElement(true)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        weak var button: NSButton?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func click() {
            action()
        }
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FittingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        nsView.textContainerInset = .zero
        nsView.textContainer?.lineFragmentPadding = 0
        nsView.textContainer?.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        nsView.layoutManager?.usesFontLeading = false
        nsView.layoutManager?.ensureLayout(for: nsView.textContainer!)
        let height = DigestCueDisplay.blockHeight(for: text, width: width)
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
