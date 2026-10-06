import Foundation

enum DigestNoteUndo {
    static let delay: TimeInterval = 5

    static func request(pending: inout [UUID: Date], id: UUID, now: Date = Date()) {
        pending[id] = now.addingTimeInterval(delay)
    }

    static func undo(pending: inout [UUID: Date], id: UUID) {
        pending.removeValue(forKey: id)
    }

    static func expiredIDs(pending: [UUID: Date], now: Date = Date()) -> [UUID] {
        pending.compactMap { id, expiresAt in
            expiresAt <= now ? id : nil
        }
    }

    static func visibleNotes(_ notes: [DigestNote], pending: [UUID: Date]) -> [DigestNote] {
        notes.filter { pending[$0.id] == nil }
    }
}
