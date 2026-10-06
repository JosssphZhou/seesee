import Foundation

enum DigestTranscriptSearch {
    static func normalizedQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matchingCueIndices(in cues: [VideoSubtitleCue], query: String) -> [Int] {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return [] }
        return cues.indices.filter { index in
            cues[index].text.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return [] }
        var hits: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            hits.append(range)
            searchStart = range.upperBound
        }
        return hits
    }

    static func step(current: Int?, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        if let current {
            let next = current + delta
            return ((next % count) + count) % count
        }
        return delta >= 0 ? 0 : count - 1
    }
}
