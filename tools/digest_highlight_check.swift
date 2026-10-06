import Foundation

@main
struct DigestHighlightCheck {
    static func main() {
        let first = DigestNote(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            time: 12.0,
            text: "Hello world.\n大家好。",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = DigestNote(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            time: 40.5,
            text: "另一句",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let notes = [first, second]

        precondition(
            DigestHighlight.isMarked(time: 12, text: "Hello world.\n大家好。", notes: notes)
        )
        precondition(
            DigestHighlight.matchingNote(time: 12.004, text: "Hello world.\n大家好。", in: notes)?.id == first.id,
            "同一句允许 0.01 秒内的时间误差"
        )
        precondition(
            !DigestHighlight.isMarked(time: 12, text: "另一句", notes: notes),
            "时间相同但文本不同不得算划线"
        )
        precondition(
            !DigestHighlight.isMarked(time: 99, text: "Hello world.\n大家好。", notes: notes)
        )

        precondition(DigestHighlight.visibleCount(notes: notes, pending: [:]) == 2)
        var pending: [UUID: Date] = [:]
        DigestNoteUndo.request(pending: &pending, id: first.id, now: Date(timeIntervalSince1970: 100))
        precondition(DigestHighlight.visibleCount(notes: notes, pending: pending) == 1)

        print("digest_highlight_check=passed")
    }
}
