import Combine
import Foundation

@MainActor
final class DigestSession: ObservableObject {
    @Published var notes: [DigestNote] = []
    @Published var pendingDeletions: [UUID: Date] = [:]
    @Published var persistMessage: String?
    @Published var showsHighlightsOnly = false
    @Published var editingCommentNoteID: UUID?
    @Published var commentDraft = ""

    private var itemID: UUID?
    private var folder: URL?
    private var noteDeleteTask: Task<Void, Never>?

    /// 启动首选条目与切换视频共用：同一条目已加载则跳过。
    func ensureLoaded(itemID: UUID, folder: URL) {
        if self.itemID == itemID, self.folder == folder { return }
        load(itemID: itemID, folder: folder)
    }

    func load(itemID: UUID, folder: URL) {
        self.itemID = itemID
        self.folder = folder
        persistMessage = nil
        switch DigestNotesStore.read(itemID: itemID, folder: folder) {
        case .ready(let loaded):
            notes = loaded.sorted { $0.createdAt > $1.createdAt }
        case .missing:
            notes = []
        case .corrupt:
            notes = []
            persistMessage = DigestCopy.fileCorrupt
        }
        pendingDeletions = [:]
        showsHighlightsOnly = false
        editingCommentNoteID = nil
        commentDraft = ""
        noteDeleteTask?.cancel()
    }

    var highlightCount: Int {
        DigestHighlight.visibleCount(notes: notes, pending: pendingDeletions)
    }

    func isHighlighted(_ cue: VideoSubtitleCue) -> Bool {
        note(for: cue) != nil
    }

    func note(for cue: VideoSubtitleCue) -> DigestNote? {
        DigestHighlightFilter.matchingVisibleNote(
            time: cue.startTime,
            text: cue.text,
            notes: notes,
            pending: pendingDeletions
        )
    }

    /// 最近一条等待撤回的划线删除。
    var latestPendingDeletionID: UUID? {
        pendingDeletions.max(by: { $0.value < $1.value })?.key
    }

    func toggleHighlightFilter() {
        showsHighlightsOnly.toggle()
    }

    func beginEditComment(noteID: UUID) {
        editingCommentNoteID = noteID
        commentDraft = notes.first(where: { $0.id == noteID })?.comment ?? ""
    }

    func cancelEditComment() {
        editingCommentNoteID = nil
        commentDraft = ""
    }

    func commitCommentDraft() {
        guard let id = editingCommentNoteID else { return }
        updateComment(noteID: id, comment: commentDraft)
    }

    var editingNote: DigestNote? {
        guard let id = editingCommentNoteID else { return nil }
        return notes.first(where: { $0.id == id })
    }

    func updateComment(noteID: UUID, comment: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        let previous = notes
        notes[index].comment = DigestNoteComment.normalized(comment)
        guard persistNotes(revertingTo: previous) else { return }
        if editingCommentNoteID == noteID {
            editingCommentNoteID = nil
            commentDraft = ""
        }
    }

    func requestDeleteNote(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        DigestNoteUndo.request(pending: &pendingDeletions, id: id)
        scheduleDeletionCommit()
    }

    func undoDeleteNote(_ id: UUID) {
        DigestNoteUndo.undo(pending: &pendingDeletions, id: id)
    }

    func commitExpiredDeletions(now: Date = Date()) {
        let expiredNotes = DigestNoteUndo.expiredIDs(pending: pendingDeletions, now: now)
        if !expiredNotes.isEmpty {
            let previous = notes
            notes.removeAll { expiredNotes.contains($0.id) }
            for id in expiredNotes {
                pendingDeletions.removeValue(forKey: id)
            }
            if !persistNotes(revertingTo: previous) {
                for id in expiredNotes {
                    DigestNoteUndo.request(pending: &pendingDeletions, id: id, now: now)
                }
            }
        }
    }

    @discardableResult
    private func persistNotes(revertingTo previous: [DigestNote]? = nil) -> Bool {
        guard let itemID, let folder else { return false }
        do {
            try DigestNotesStore.save(notes, itemID: itemID, folder: folder)
            if persistMessage == DigestCopy.saveFailed {
                persistMessage = nil
            }
            return true
        } catch {
            if let previous {
                notes = previous
            }
            persistMessage = DigestCopy.saveFailed
            return false
        }
    }

    private func scheduleDeletionCommit() {
        noteDeleteTask?.cancel()
        noteDeleteTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let session = self else { return }
                let now = Date()
                session.commitExpiredDeletions(now: now)
                guard let next = session.pendingDeletions.values.min() else { return }
                let wait = next.timeIntervalSince(now)
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
        }
    }

    @discardableResult
    func toggleHighlight(cue: VideoSubtitleCue) -> DigestHighlightToggle.Action {
        let action = DigestHighlightToggle.action(
            time: cue.startTime,
            text: cue.text,
            notes: notes,
            pending: pendingDeletions
        )
        switch action {
        case .requestDelete(let id):
            editingCommentNoteID = nil
            commentDraft = ""
            requestDeleteNote(id)
        case .undoDelete(let id):
            undoDeleteNote(id)
        case .add:
            let captured = DigestNoteCapture.sources(
                selected: cue.text,
                hintIndex: 0,
                cues: [DigestNoteSource(startTime: cue.startTime, text: cue.text)]
            )
            guard let source = captured.first else { return action }
            let previous = notes
            let note = DigestNote(id: UUID(), time: source.startTime, text: source.text, createdAt: Date())
            notes.insert(note, at: 0)
            if persistNotes(revertingTo: previous) {
                editingCommentNoteID = note.id
                commentDraft = ""
            }
        }
        return action
    }
}
