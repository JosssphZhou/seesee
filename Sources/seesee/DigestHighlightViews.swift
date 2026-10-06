import AppKit
import SwiftUI

struct DigestHighlightCommentRow: View {
    let text: String
    var onBeginEdit: () -> Void = {}

    var body: some View {
        if DigestNoteComment.shouldDisplay(text) {
            HStack(alignment: .center, spacing: 6) {
                Text(text)
                    .font(.system(size: DigestBookChrome.commentSavedSize))
                    .foregroundStyle(OpenMyChrome.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(OpenMyChrome.faint)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: DigestBookHitKey.self,
                                value: ["comment-pen": proxy.frame(in: .named("digest-book-page"))]
                            )
                        }
                    )
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onBeginEdit)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DigestBookHitKey.self,
                        value: ["comment": proxy.frame(in: .named("digest-book-page"))]
                    )
                }
            )
            .accessibilityLabel(text)
            .accessibilityHint("编辑批语")
        }
    }
}

struct DigestCommentBar: View {
    let timeLabel: String
    let sentence: String
    let draft: String
    var onDraftChange: (String) -> Void = { _ in }
    var onSave: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(DigestBookChrome.commentBarLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OpenMyChrome.muted)
                Text(timeLabel)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(OpenMyChrome.faint)
                Text(sentence)
                    .font(.system(size: 10))
                    .foregroundStyle(OpenMyChrome.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DigestBookHitKey.self,
                        value: ["comment-bar-caption": proxy.frame(in: .named("digest-book-page"))]
                    )
                }
            )
            DigestHighlightCommentField(
                text: draft,
                onSave: onSave,
                onCancel: onCancel,
                onDraftChange: onDraftChange
            )
            .frame(maxWidth: .infinity)
            .frame(height: DigestBookChrome.commentFieldHeight)
        }
        .padding(.horizontal, DigestBookChrome.headerHorizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenMyChrome.canvas)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OpenMyChrome.hair)
                .frame(height: 1)
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DigestBookHitKey.self,
                    value: ["comment-bar": proxy.frame(in: .named("digest-book-page"))]
                )
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DigestBookChrome.commentBarLabel)
    }
}

final class DigestCommentFieldView: NSView, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    let hintLabel = NSTextField(labelWithString: DigestBookChrome.commentHintIdle)
    var onSave: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onDraftChange: (String) -> Void = { _ in }
    var parentText = ""
    private var didCommit = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyChrome(focused: false)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 12)
        field.textColor = OpenMyChrome.nsInk
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = self

        hintLabel.isEditable = false
        hintLabel.isSelectable = false
        hintLabel.isBordered = false
        hintLabel.drawsBackground = false
        hintLabel.font = NSFont.systemFont(ofSize: DigestBookChrome.commentHintSize)
        hintLabel.textColor = OpenMyChrome.nsFaint
        hintLabel.alignment = .right
        hintLabel.lineBreakMode = .byClipping

        addSubview(field)
        addSubview(hintLabel)
        applyPlaceholder()
        refreshHint()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let pad = DigestBookChrome.commentFieldPadding
        let hint = hintLabel.stringValue
        let show = DigestCommentHintLayout.shouldShow(columnWidth: bounds.width, hint: hint)
        hintLabel.isHidden = !show
        if show {
            let hintWidth = DigestCommentHintLayout.width(of: hint)
            hintLabel.frame = NSRect(
                x: bounds.width - pad - hintWidth,
                y: 0,
                width: hintWidth,
                height: bounds.height
            )
            field.frame = NSRect(
                x: pad,
                y: 0,
                width: max(0, hintLabel.frame.minX - DigestBookChrome.commentHintSpacing - pad),
                height: bounds.height
            )
        } else {
            hintLabel.frame = .zero
            field.frame = NSRect(
                x: pad,
                y: 0,
                width: max(0, bounds.width - pad * 2),
                height: bounds.height
            )
        }
    }

    func applyChrome(focused: Bool) {
        layer?.backgroundColor = OpenMyChrome.nsRaise.cgColor
        layer?.cornerRadius = OpenMyChrome.radiusSm
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = (focused ? OpenMyChrome.nsRowSelectedStroke : OpenMyChrome.nsFieldBorder).cgColor
    }

    func applyPlaceholder() {
        field.placeholderAttributedString = NSAttributedString(
            string: DigestBookChrome.commentPlaceholder,
            attributes: [
                .foregroundColor: OpenMyChrome.nsFaint,
                .font: NSFont.systemFont(ofSize: 12)
            ]
        )
    }

    func refreshHint() {
        hintLabel.stringValue = field.stringValue.isEmpty
            ? DigestBookChrome.commentHintIdle
            : DigestBookChrome.commentHintTyping
        needsLayout = true
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            didCommit = true
            onSave(control.stringValue)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            didCommit = true
            onCancel()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshHint()
        onDraftChange(field.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        applyChrome(focused: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        applyChrome(focused: false)
        if didCommit { return }
        onSave(field.stringValue)
    }
}

struct DigestHighlightCommentField: NSViewRepresentable {
    var text: String
    var onSave: (String) -> Void
    var onCancel: () -> Void = {}
    var onDraftChange: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> DigestCommentFieldView {
        let view = DigestCommentFieldView(frame: .zero)
        view.field.stringValue = text
        view.parentText = text
        view.onSave = onSave
        view.onCancel = onCancel
        view.onDraftChange = onDraftChange
        view.applyPlaceholder()
        view.refreshHint()
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view.field)
        }
        return view
    }

    func updateNSView(_ view: DigestCommentFieldView, context: Context) {
        view.parentText = text
        view.onSave = onSave
        view.onCancel = onCancel
        view.onDraftChange = onDraftChange
        view.applyPlaceholder()
        if view.field.currentEditor() == nil, view.field.stringValue != text {
            view.field.stringValue = text
            view.refreshHint()
        }
    }
}

struct DigestCollapsedHint: View {
    let hiddenCount: Int

    var body: some View {
        Text(DigestHighlightFilter.collapsedHint(hiddenCount))
            .font(.system(size: 12))
            .foregroundStyle(OpenMyChrome.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DigestBookHitKey.self,
                        value: ["collapsed-hint": proxy.frame(in: .named("digest-book-page"))]
                    )
                }
            )
            .accessibilityLabel(DigestHighlightFilter.collapsedHint(hiddenCount))
    }
}
