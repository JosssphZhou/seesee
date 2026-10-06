import Foundation

struct DigestNote: Codable, Equatable, Identifiable {
    var id: UUID
    var time: Double
    var text: String
    var createdAt: Date
    var comment: String?
}

enum DigestNoteComment {
    static func normalized(_ raw: String?) -> String? {
        let collapsed = (raw ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    static func shouldDisplay(_ raw: String?) -> Bool {
        normalized(raw) != nil
    }
}

struct DigestNoteSource: Equatable {
    var startTime: Double
    var text: String
}

enum DigestNoteCapture {
    static func sources(
        selected: String,
        hintIndex: Int,
        cues: [DigestNoteSource]
    ) -> [DigestNoteSource] {
        guard !cues.isEmpty else { return [] }
        let needle = fold(selected)
        guard !needle.isEmpty else { return [] }
        let hint = cues.indices.contains(hintIndex) ? hintIndex : 0
        var indices = [hint]
        if !fold(cues[hint].text).localizedStandardContains(needle) {
            if hint > 0, fold(cues[hint - 1].text + "\n" + cues[hint].text).localizedStandardContains(needle) {
                indices.insert(hint - 1, at: 0)
            } else if hint + 1 < cues.count,
                      fold(cues[hint].text + "\n" + cues[hint + 1].text).localizedStandardContains(needle) {
                indices.append(hint + 1)
            }
        }
        return indices.map { cues[$0] }
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DigestHighlight {
    static let timeTolerance = 0.01

    static func matchingNote(time: Double, text: String, in notes: [DigestNote]) -> DigestNote? {
        notes.first { note in
            abs(note.time - time) < timeTolerance && note.text == text
        }
    }

    static func isMarked(time: Double, text: String, notes: [DigestNote]) -> Bool {
        matchingNote(time: time, text: text, in: notes) != nil
    }

    static func visibleCount(notes: [DigestNote], pending: [UUID: Date]) -> Int {
        notes.filter { pending[$0.id] == nil }.count
    }
}

enum DigestNotesStore {
    static let sidecarSuffix = "notes.json"

    enum Read: Equatable {
        case missing
        case ready([DigestNote])
        case corrupt
    }

    static func fileURL(itemID: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent("\(itemID.uuidString).\(sidecarSuffix)")
    }

    static func load(itemID: UUID, folder: URL) -> [DigestNote] {
        load(from: fileURL(itemID: itemID, in: folder))
    }

    static func load(from url: URL) -> [DigestNote] {
        switch read(from: url) {
        case .ready(let notes):
            return notes
        case .missing, .corrupt:
            return []
        }
    }

    static func read(itemID: UUID, folder: URL) -> Read {
        read(from: fileURL(itemID: itemID, in: folder))
    }

    static func read(from url: URL) -> Read {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .corrupt
        }
        if data.isEmpty { return .missing }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .ready(try decoder.decode([DigestNote].self, from: data))
        } catch {
            return .corrupt
        }
    }

    static func save(_ notes: [DigestNote], itemID: UUID, folder: URL) throws {
        try save(notes, to: fileURL(itemID: itemID, in: folder))
    }

    static func save(_ notes: [DigestNote], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(notes)
        try data.write(to: url, options: .atomic)
    }
}
