import Foundation

enum DigestHighlightFilter {
    static func visibleIndices(
        cues: [DigestNoteSource],
        notes: [DigestNote],
        pending: [UUID: Date],
        highlightsOnly: Bool
    ) -> [Int] {
        let visibleNotes = DigestNoteUndo.visibleNotes(notes, pending: pending)
        return cues.indices.filter { index in
            if !highlightsOnly { return true }
            let cue = cues[index]
            return DigestHighlight.isMarked(time: cue.startTime, text: cue.text, notes: visibleNotes)
        }
    }

    static func hiddenCount(total: Int, visible: Int) -> Int {
        max(0, total - visible)
    }

    static func collapsedHint(_ hiddenCount: Int) -> String {
        "其余 \(hiddenCount) 句已收起"
    }

    static func matchingVisibleNote(
        time: Double,
        text: String,
        notes: [DigestNote],
        pending: [UUID: Date]
    ) -> DigestNote? {
        DigestHighlight.matchingNote(
            time: time,
            text: text,
            in: DigestNoteUndo.visibleNotes(notes, pending: pending)
        )
    }

    static func scrollTarget(visibleIndices: [Int], anchor: Int?) -> Int? {
        if let anchor, visibleIndices.contains(anchor) { return anchor }
        return visibleIndices.first
    }

    /// 进入只看划线时记下阅读位置；过滤中滚动不得改写。
    static func enterAnchor(reading: Int?, visible: [Int]) -> Int? {
        scrollTarget(visibleIndices: visible, anchor: reading)
    }

    /// 退出时用进入时记下的锚点。
    static func exitTarget(stored: Int?, visible: [Int]) -> Int? {
        scrollTarget(visibleIndices: visible, anchor: stored)
    }
}

enum DigestHighlightToggle {
    enum Action: Equatable {
        case add
        case requestDelete(UUID)
        case undoDelete(UUID)
    }

    static func action(
        time: Double,
        text: String,
        notes: [DigestNote],
        pending: [UUID: Date]
    ) -> Action {
        let visibleNotes = DigestNoteUndo.visibleNotes(notes, pending: pending)
        if let existing = DigestHighlight.matchingNote(time: time, text: text, in: visibleNotes) {
            return .requestDelete(existing.id)
        }
        let pendingNotes = notes.filter { pending[$0.id] != nil }
        if let hidden = DigestHighlight.matchingNote(time: time, text: text, in: pendingNotes) {
            return .undoDelete(hidden.id)
        }
        return .add
    }
}
