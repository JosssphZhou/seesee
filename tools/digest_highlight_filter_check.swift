import Foundation

@main
struct DigestHighlightFilterCheck {
    static func main() {
        checkFilterKeepsVideoOrder()
        checkPendingDeletionHiddenFromFilter()
        checkCollapsedHint()
        checkToggleActions()
        checkScrollRestoreAnchor()
        checkEnterExitAnchorIgnoresFilterScroll()
        print("digest_highlight_filter_check=passed")
    }

    private static func sampleCues() -> [DigestNoteSource] {
        [
            DigestNoteSource(startTime: 10, text: "第一句"),
            DigestNoteSource(startTime: 20, text: "第二句"),
            DigestNoteSource(startTime: 30, text: "第三句"),
            DigestNoteSource(startTime: 40, text: "第四句")
        ]
    }

    private static func checkFilterKeepsVideoOrder() {
        let cues = sampleCues()
        let later = DigestNote(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            time: 40,
            text: "第四句",
            createdAt: Date(timeIntervalSince1970: 20),
            comment: "后写的"
        )
        let earlier = DigestNote(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            time: 10,
            text: "第一句",
            createdAt: Date(timeIntervalSince1970: 30),
            comment: "先写的"
        )
        let notes = [earlier, later]

        let all = DigestHighlightFilter.visibleIndices(
            cues: cues,
            notes: notes,
            pending: [:],
            highlightsOnly: false
        )
        precondition(all == [0, 1, 2, 3], "全文须保持视频顺序")

        let filtered = DigestHighlightFilter.visibleIndices(
            cues: cues,
            notes: notes,
            pending: [:],
            highlightsOnly: true
        )
        precondition(filtered == [0, 3], "只看划线须按视频顺序，不得按创建时间")
        precondition(
            DigestHighlightFilter.hiddenCount(total: cues.count, visible: filtered.count) == 2
        )
        precondition(DigestHighlight.visibleCount(notes: notes, pending: [:]) == 2)
    }

    private static func checkPendingDeletionHiddenFromFilter() {
        let cues = sampleCues()
        let first = DigestNote(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            time: 10,
            text: "第一句",
            createdAt: Date(timeIntervalSince1970: 1),
            comment: "会撤回"
        )
        let last = DigestNote(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            time: 40,
            text: "第四句",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        var pending: [UUID: Date] = [:]
        DigestNoteUndo.request(pending: &pending, id: first.id, now: Date(timeIntervalSince1970: 100))

        let filtered = DigestHighlightFilter.visibleIndices(
            cues: cues,
            notes: [first, last],
            pending: pending,
            highlightsOnly: true
        )
        precondition(filtered == [3], "待撤销的划线不得出现在只看划线里")
        precondition(DigestHighlight.visibleCount(notes: [first, last], pending: pending) == 1)
        DigestNoteUndo.undo(pending: &pending, id: first.id)
        let restored = DigestHighlightFilter.visibleIndices(
            cues: cues,
            notes: [first, last],
            pending: pending,
            highlightsOnly: true
        )
        precondition(restored == [0, 3])
        precondition(DigestHighlightFilter.matchingVisibleNote(
            time: 10,
            text: "第一句",
            notes: [first, last],
            pending: pending
        )?.comment == "会撤回")
    }

    private static func checkCollapsedHint() {
        precondition(DigestHighlightFilter.collapsedHint(3) == "其余 3 句已收起")
        precondition(DigestHighlightFilter.collapsedHint(1) == "其余 1 句已收起")
        precondition(DigestHighlightFilter.hiddenCount(total: 5, visible: 5) == 0)
        precondition(DigestHighlightFilter.hiddenCount(total: 5, visible: 2) == 3)
    }

    private static func checkToggleActions() {
        let note = DigestNote(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            time: 20,
            text: "第二句",
            createdAt: Date(timeIntervalSince1970: 1),
            comment: "批"
        )
        precondition(
            DigestHighlightToggle.action(
                time: 20,
                text: "第二句",
                notes: [note],
                pending: [:]
            ) == .requestDelete(note.id)
        )
        precondition(
            DigestHighlightToggle.action(
                time: 30,
                text: "第三句",
                notes: [note],
                pending: [:]
            ) == .add
        )

        var pending: [UUID: Date] = [:]
        DigestNoteUndo.request(pending: &pending, id: note.id, now: Date(timeIntervalSince1970: 100))
        precondition(
            DigestHighlightToggle.action(
                time: 20,
                text: "第二句",
                notes: [note],
                pending: pending
            ) == .undoDelete(note.id),
            "取消划线尚未提交时再点划线应撤回删除"
        )
    }

    private static func checkScrollRestoreAnchor() {
        precondition(
            DigestHighlightFilter.scrollTarget(
                visibleIndices: [0, 3],
                anchor: 3
            ) == 3
        )
        precondition(
            DigestHighlightFilter.scrollTarget(
                visibleIndices: [0, 3],
                anchor: 1
            ) == 0,
            "锚点不在可见列表时滚到第一条划线"
        )
        precondition(
            DigestHighlightFilter.scrollTarget(
                visibleIndices: [0, 1, 2, 3],
                anchor: 1
            ) == 1,
            "回到全文时停在原锚点附近"
        )
        precondition(
            DigestHighlightFilter.scrollTarget(visibleIndices: [], anchor: 2) == nil
        )
    }

    private static func checkEnterExitAnchorIgnoresFilterScroll() {
        let stored = DigestHighlightFilter.enterAnchor(reading: 2, visible: [0, 1, 2, 3])
        precondition(stored == 2, "进入只看划线须记下当时阅读句")
        let scrolledDuringFilter = 0
        precondition(
            DigestHighlightFilter.exitTarget(stored: stored, visible: [0, 1, 2, 3]) == 2,
            "退出时用进入时的锚点，过滤中滚动不得覆盖。误用 \(scrolledDuringFilter) 会滚走"
        )
        precondition(
            DigestHighlightFilter.exitTarget(stored: stored, visible: [0, 3]) == 3
                || DigestHighlightFilter.exitTarget(stored: stored, visible: [0, 3]) == 0,
            "锚点句未划线时回落到可见列表"
        )
        precondition(DigestHighlightFilter.exitTarget(stored: 2, visible: [0, 3]) == 0)
    }
}
