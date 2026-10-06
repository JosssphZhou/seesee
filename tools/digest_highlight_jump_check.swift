import AppKit
import SwiftUI

/// 诊断：点划线前后各句 y 坐标差。先打印，定位跳动来源后再改成断言。
@main
struct DigestHighlightJumpCheck {
    static let canvasWidth = 360
    static let shortHeight = 280
    static let tallHeight = 720
    static let targetIndex = 3
    static let timeColumnWidth: CGFloat = 52

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        OpenMyChrome.applyAppearance()

        let cues = sampleCues()
        precondition(cues.count >= 8, "诊断字幕书须至少 8 句")

        print("digest_highlight_jump_check cues=\(cues.count) target=\(targetIndex)")

        let highlighted = run(
            name: "矮窗-点划线",
            cues: cues,
            height: shortHeight,
            hoverBefore: false,
            hoverAfter: .held,
            scrollToCurrent: false
        )
        assertStableCues(highlighted, name: "矮窗-点划线")
        assertScrollUnchanged(highlighted, name: "矮窗-点划线")

        let cancelled = run(
            name: "矮窗-取消划线",
            cues: cues,
            height: shortHeight,
            hoverBefore: false,
            hoverAfter: .held,
            scrollToCurrent: false,
            extra: { model in
                model.toggleHighlight(at: targetIndex)
                model.hoveredIndex = nil
            }
        )
        assertStableCues(cancelled, name: "矮窗-取消划线")
        assertScrollUnchanged(cancelled, name: "矮窗-取消划线")

        let tall = run(
            name: "高窗-点划线",
            cues: cues,
            height: tallHeight,
            hoverBefore: false,
            hoverAfter: .held,
            scrollToCurrent: false
        )
        assertStableCues(tall, name: "高窗-点划线")
        assertScrollUnchanged(tall, name: "高窗-点划线")

        print("digest_highlight_jump_check=passed")
    }

    private enum HoverAfter {
        case held
        case cleared
    }

    @MainActor
    @discardableResult
    private static func run(
        name: String,
        cues: [VideoSubtitleCue],
        height: Int,
        hoverBefore: Bool,
        hoverAfter: HoverAfter,
        scrollToCurrent: Bool,
        extra: ((JumpModel) -> Void)? = nil
    ) -> (before: JumpSnapshot, after: JumpSnapshot) {
        let sink = JumpHitSink()
        let model = JumpModel(
            cues: cues,
            currentIndex: targetIndex,
            hoveredIndex: hoverBefore ? targetIndex : nil
        )
        let hosting = makeHosting(model: model, sink: sink, height: height)
        let window = makeWindow(hosting: hosting, height: height)
        layout(hosting: hosting, window: window)
        if let scroll = findScrollView(in: hosting) {
            model.scrollLock.attach(to: scroll)
        }
        extra?(model)
        if extra != nil {
            layout(hosting: hosting, window: window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            layout(hosting: hosting, window: window)
        }

        let before = snapshot(from: sink, cues: cues, hosting: hosting, label: "before")
        model.toggleHighlight(at: targetIndex)
        if hoverAfter == .cleared {
            model.hoveredIndex = nil
        }
        if scrollToCurrent {
            model.followScrollToken &+= 1
        }
        layout(hosting: hosting, window: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        layout(hosting: hosting, window: window)
        let after = snapshot(from: sink, cues: cues, hosting: hosting, label: "after")

        printScenario(name: name, before: before, samples: [("after", after)])
        window.close()
        return (before, after)
    }

    private static func assertStableCues(
        _ result: (before: JumpSnapshot, after: JumpSnapshot),
        name: String
    ) {
        for index in result.before.pageYs.indices {
            let before = result.before.pageYs[index]
            let after = result.after.pageYs[index]
            guard before.isFinite else { continue }
            precondition(
                after.isFinite,
                "\(name) cue[\(index)] 划线后须仍能测到 y：before=\(fmt(before))"
            )
            let dy = after - before
            precondition(
                abs(dy) < 0.5,
                "\(name) cue[\(index)] 划线前后 y 差须为 0，实际 \(fmt(dy))（before=\(fmt(before)) after=\(fmt(after))）"
            )
        }
    }

    private static func assertScrollUnchanged(
        _ result: (before: JumpSnapshot, after: JumpSnapshot),
        name: String
    ) {
        precondition(
            abs(result.after.scrollY - result.before.scrollY) < 0.5,
            "\(name) 输入条出现后 contentOffset 须不变：before=\(fmt(result.before.scrollY)) after=\(fmt(result.after.scrollY))"
        )
    }

    @MainActor
    private static func makeHosting(
        model: JumpModel,
        sink: JumpHitSink,
        height: Int
    ) -> NSHostingView<JumpBookView> {
        let root = JumpBookView(
            model: model,
            sink: sink,
            canvasWidth: canvasWidth,
            canvasHeight: height
        )
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: height)
        return hosting
    }

    @MainActor
    private static func makeWindow(hosting: NSView, height: Int) -> NSWindow {
        let window = OneXWindow(
            contentRect: NSRect(x: 0, y: 0, width: canvasWidth, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = OpenMyChrome.nsCanvas
        window.contentView = hosting
        window.orderBack(nil)
        return window
    }

    @MainActor
    private static func layout(hosting: NSView, window: NSWindow) {
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        hosting.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    private static func snapshot(
        from sink: JumpHitSink,
        cues: [VideoSubtitleCue],
        hosting: NSView,
        label: String
    ) -> JumpSnapshot {
        var pageYs: [CGFloat] = []
        var contentYs: [CGFloat] = []
        for index in cues.indices {
            pageYs.append(sink.hits["cue-\(index)"]?.minY ?? .nan)
            contentYs.append(sink.hits["content-\(index)"]?.minY ?? .nan)
        }
        return JumpSnapshot(
            label: label,
            pageYs: pageYs,
            contentYs: contentYs,
            scrollY: findScrollView(in: hosting)?.contentView.bounds.origin.y ?? .nan,
            commentY: sink.hits["comment"]?.minY,
            highlightActionY: sink.hits["highlight-action"]?.minY,
            undoY: sink.hits["undo"]?.minY
        )
    }

    private static func printScenario(
        name: String,
        before: JumpSnapshot,
        samples: [(String, JumpSnapshot)]
    ) {
        print("---- \(name) ----")
        print(
            "  scroll before=\(fmt(before.scrollY))"
            + samples.map { " \($0)=\(fmt($1.scrollY))" }.joined()
        )
        print(
            "  comment before=\(fmtOpt(before.commentY))"
            + samples.map { " \($0)=\(fmtOpt($1.commentY))" }.joined()
        )
        print(
            "  highlight-action before=\(fmtOpt(before.highlightActionY))"
            + samples.map { " \($0)=\(fmtOpt($1.highlightActionY))" }.joined()
        )
        print(
            "  undo before=\(fmtOpt(before.undoY))"
            + samples.map { " \($0)=\(fmtOpt($1.undoY))" }.joined()
        )
        for index in before.pageYs.indices {
            let mark = index == targetIndex ? " TARGET" : (index < targetIndex ? " above" : " below")
            var line = "  cue[\(index)]\(mark) page \(fmt(before.pageYs[index]))"
            for (label, sample) in samples {
                let dy = sample.pageYs[index] - before.pageYs[index]
                line += " \(label)=\(fmt(sample.pageYs[index])) dy=\(fmt(dy))"
            }
            line += " | content \(fmt(before.contentYs[index]))"
            for (label, sample) in samples {
                let dy = sample.contentYs[index] - before.contentYs[index]
                line += " \(label)Dy=\(fmt(dy))"
            }
            print(line)
        }
    }

    private static func fmt(_ value: CGFloat) -> String {
        guard value.isFinite else { return "n/a" }
        return String(format: "%.2f", Double(value))
    }

    private static func fmtOpt(_ value: CGFloat?) -> String {
        guard let value else { return "nil" }
        return fmt(value)
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = findScrollView(in: child) { return found }
        }
        return nil
    }

    private static func sampleCues() -> [VideoSubtitleCue] {
        [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "Hello world.\n大家好。"),
            VideoSubtitleCue(startTime: 2, endTime: 4, text: "This is the second sentence.\n这是第二句。"),
            VideoSubtitleCue(startTime: 4, endTime: 6, text: "Agents can plan.\n智能体可以做计划。"),
            VideoSubtitleCue(startTime: 6, endTime: 8, text: "Keep going through the list.\n继续往下看清单。"),
            VideoSubtitleCue(startTime: 8, endTime: 10, text: "Another bilingual block.\n又一块双语字幕。"),
            VideoSubtitleCue(startTime: 10, endTime: 12, text: "Enough rows to overflow.\n行数要够才能溢出。"),
            VideoSubtitleCue(startTime: 12, endTime: 14, text: "The seventh sentence stays put.\n第七句应该稳住。"),
            VideoSubtitleCue(startTime: 14, endTime: 16, text: "Last visible after scrolling.\n滚动之后才看见这句。"),
            VideoSubtitleCue(startTime: 16, endTime: 18, text: "One more line for coverage.\n再补一句凑满。")
        ]
    }
}

@MainActor
final class JumpModel: ObservableObject {
    let cues: [VideoSubtitleCue]
    @Published var notes: [DigestNote] = []
    @Published var pendingDeletions: [UUID: Date] = [:]
    @Published var editingCommentNoteID: UUID?
    @Published var hoveredIndex: Int?
    @Published var currentIndex: Int?
    @Published var followScrollToken = 0
    let scrollLock = DigestScrollLock()

    init(cues: [VideoSubtitleCue], currentIndex: Int?, hoveredIndex: Int?) {
        self.cues = cues
        self.currentIndex = currentIndex
        self.hoveredIndex = hoveredIndex
    }

    func toggleHighlight(at index: Int) {
        scrollLock.freeze()
        let cue = cues[index]
        let action = DigestHighlightToggle.action(
            time: cue.startTime,
            text: cue.text,
            notes: notes,
            pending: pendingDeletions
        )
        switch action {
        case .requestDelete(let id):
            editingCommentNoteID = nil
            DigestNoteUndo.request(pending: &pendingDeletions, id: id)
        case .undoDelete(let id):
            DigestNoteUndo.undo(pending: &pendingDeletions, id: id)
        case .add:
            let note = DigestNote(
                id: UUID(),
                time: cue.startTime,
                text: cue.text,
                createdAt: Date()
            )
            notes.insert(note, at: 0)
            editingCommentNoteID = note.id
        }
    }

    func note(for cue: VideoSubtitleCue) -> DigestNote? {
        DigestHighlightFilter.matchingVisibleNote(
            time: cue.startTime,
            text: cue.text,
            notes: notes,
            pending: pendingDeletions
        )
    }

    func isHighlighted(_ cue: VideoSubtitleCue) -> Bool {
        note(for: cue) != nil
    }
}

final class JumpHitSink {
    var hits: [String: CGRect] = [:]
}

private struct JumpBookView: View {
    @ObservedObject var model: JumpModel
    let sink: JumpHitSink
    let canvasWidth: Int
    let canvasHeight: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DigestBookToolbar(
                query: "",
                onQueryChange: { _ in },
                matchCount: 0,
                activeIndex: nil,
                highlightCount: DigestHighlight.visibleCount(
                    notes: model.notes,
                    pending: model.pendingDeletions
                ),
                step: { _ in }
            )
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DigestCueDisplay.blockSpacing) {
                            ForEach(model.cues.indices, id: \.self) { index in
                                cueRow(index: index)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .coordinateSpace(name: "digest-book-content")
                        .background {
                            DigestScrollLockMonitor(lock: model.scrollLock)
                                .frame(width: 0, height: 0)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.followScrollToken) { _ in
                        guard let current = model.currentIndex else { return }
                        withAnimation(.easeInOut(duration: 0.22)) {
                            proxy.scrollTo(current, anchor: .center)
                        }
                    }
                }
                if model.notes.contains(where: { model.pendingDeletions[$0.id] != nil }) {
                    DigestNoteUndoBar(onUndo: {})
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                if let id = model.editingCommentNoteID,
                   let note = model.notes.first(where: { $0.id == id }) {
                    DigestCommentBar(
                        timeLabel: timeLabel(note.time),
                        sentence: DigestCueDisplay.lines(from: note.text).translation,
                        draft: ""
                    )
                }
            }
        }
        .frame(width: CGFloat(canvasWidth), height: CGFloat(canvasHeight), alignment: .top)
        .background(OpenMyChrome.canvas)
        .coordinateSpace(name: "digest-book-page")
        .onPreferenceChange(DigestBookHitKey.self) { sink.hits = $0 }
    }

    @ViewBuilder
    private func cueRow(index: Int) -> some View {
        let cue = model.cues[index]
        VStack(alignment: .leading, spacing: 0) {
            DigestCueRow(
                timeLabel: timeLabel(cue.startTime),
                cueText: cue.text,
                timeColumnWidth: DigestHighlightJumpCheck.timeColumnWidth,
                isCurrent: model.currentIndex == index,
                isHighlighted: model.isHighlighted(cue),
                showsActions: model.hoveredIndex == index,
                onHighlight: { model.toggleHighlight(at: index) },
                highlightTitle: model.isHighlighted(cue)
                    ? DigestBookChrome.unhighlightTitle
                    : DigestBookChrome.highlightTitle
            )
            if let note = model.note(for: cue), DigestNoteComment.shouldDisplay(note.comment) {
                DigestHighlightCommentRow(text: note.comment ?? "")
                    .padding(.top, DigestBookChrome.commentFieldSpacing)
                    .padding(.leading, DigestHighlightJumpCheck.timeColumnWidth + 10)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, DigestCueDisplay.rowVerticalPadding)
        .background {
            if model.currentIndex == index {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DigestBookHitKey.self,
                    value: [
                        "cue-\(index)": proxy.frame(in: .named("digest-book-page")),
                        "content-\(index)": proxy.frame(in: .named("digest-book-content"))
                    ]
                )
            }
        )
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 1 }
}

struct JumpSnapshot {
    var label: String
    var pageYs: [CGFloat]
    var contentYs: [CGFloat]
    var scrollY: CGFloat
    var commentY: CGFloat?
    var highlightActionY: CGFloat?
    var undoY: CGFloat?
}
