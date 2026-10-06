import Foundation

@main
struct DigestNoteUndoCheck {
    static func main() {
        let first = DigestNote(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            time: 12,
            text: "不同的方面",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = DigestNote(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            time: 40,
            text: "另一条",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        var pending: [UUID: Date] = [:]
        let now = Date(timeIntervalSince1970: 100)

        DigestNoteUndo.request(pending: &pending, id: first.id, now: now)
        precondition(pending[first.id] == now.addingTimeInterval(5))
        precondition(DigestNoteUndo.visibleNotes([first, second], pending: pending).map(\.id) == [second.id])
        precondition(DigestNoteUndo.expiredIDs(pending: pending, now: now.addingTimeInterval(4.9)).isEmpty)

        DigestNoteUndo.undo(pending: &pending, id: first.id)
        precondition(pending.isEmpty)
        precondition(DigestNoteUndo.visibleNotes([first, second], pending: pending).count == 2)

        DigestNoteUndo.request(pending: &pending, id: first.id, now: now)
        let expired = DigestNoteUndo.expiredIDs(pending: pending, now: now.addingTimeInterval(5))
        precondition(expired == [first.id])

        checkUndoRestoresComment()
        print("digest_note_undo_check=passed")
    }

    private static func checkUndoRestoresComment() {
        let noted = DigestNote(
            id: UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000")!,
            time: 18,
            text: "划过的句子",
            createdAt: Date(timeIntervalSince1970: 3),
            comment: "当时的想法"
        )
        var pending: [UUID: Date] = [:]
        let now = Date(timeIntervalSince1970: 200)

        DigestNoteUndo.request(pending: &pending, id: noted.id, now: now)
        precondition(DigestNoteUndo.visibleNotes([noted], pending: pending).isEmpty)
        DigestNoteUndo.undo(pending: &pending, id: noted.id)
        let restored = DigestNoteUndo.visibleNotes([noted], pending: pending)
        precondition(restored.count == 1)
        precondition(restored[0].comment == "当时的想法", "撤销须连批语一起恢复")
        precondition(restored[0].text == "划过的句子")
    }
}
