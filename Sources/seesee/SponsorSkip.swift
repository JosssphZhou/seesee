import Foundation

enum YouTubeVideoID {
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func extract(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return nil }

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let videoID = url.path.split(separator: "/").first.map(String.init) ?? ""
            return isValid(videoID) ? videoID : nil
        }

        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        let videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value ?? ""
        return isValid(videoID) ? videoID : nil
    }

    private static func isValid(_ videoID: String) -> Bool {
        videoID.count == 11 && videoID.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

struct SponsorSegment: Equatable {
    let start: Double
    let end: Double
    let category: String

    func contains(_ time: Double) -> Bool {
        time.isFinite && time >= start && time < end
    }
}

struct SponsorSkipDecision: Equatable {
    let end: Double
    let skippedDuration: Double
}

struct SponsorSkipSession {
    private(set) var segments: [SponsorSegment] = []
    private var skippedStarts: Set<Double> = []

    mutating func replaceSegments(_ segments: [SponsorSegment]) {
        self.segments = Self.merged(segments.filter { $0.end > $0.start && $0.start.isFinite && $0.end.isFinite })
        skippedStarts.removeAll()
    }

    mutating func reset() {
        segments = []
        skippedStarts.removeAll()
    }

    mutating func consumeSkip(at time: Double) -> SponsorSkipDecision? {
        guard time.isFinite,
              let segment = segments.first(where: { $0.contains(time) && !skippedStarts.contains($0.start) })
        else { return nil }
        skippedStarts.insert(segment.start)
        return SponsorSkipDecision(end: segment.end, skippedDuration: max(0, segment.end - time))
    }

    private static func merged(_ segments: [SponsorSegment]) -> [SponsorSegment] {
        let sorted = segments.sorted { $0.start < $1.start }
        var result: [SponsorSegment] = []
        for segment in sorted {
            guard let last = result.last, segment.start <= last.end else {
                result.append(segment)
                continue
            }
            result[result.count - 1] = SponsorSegment(
                start: last.start,
                end: max(last.end, segment.end),
                category: last.category
            )
        }
        return result
    }
}

enum SponsorSkipMessage {
    static func text(skippedDuration: Double) -> String {
        let seconds = max(1, Int(skippedDuration.rounded()))
        return "已跳过赞助段 \(seconds) 秒"
    }
}

enum SponsorSkipPreference {
    static let key = "skipSponsorSegments"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

enum SponsorBlockPayload {
    private struct RawSegment: Decodable {
        let category: String?
        let actionType: String?
        let segment: [Double]?
    }

    static func segments(from data: Data) -> [SponsorSegment] {
        guard let raw = try? JSONDecoder().decode([RawSegment].self, from: data) else { return [] }
        return raw.compactMap { item in
            let action = item.actionType ?? "skip"
            let category = item.category ?? ""
            guard action == "skip",
                  category == "sponsor" || category == "selfpromo",
                  let pair = item.segment,
                  pair.count == 2 else { return nil }
            return SponsorSegment(
                start: pair[0],
                end: pair[1],
                category: category
            )
        }
    }
}

enum SponsorBlockClient {
    static let endpoint = URL(string: "https://sponsor.ajay.app/api/skipSegments")!

    @discardableResult
    static func fetch(
        videoID: String,
        session: URLSession = .shared,
        completion: @escaping ([SponsorSegment]) -> Void
    ) -> URLSessionDataTask? {
        guard YouTubeVideoID.extract(from: "https://www.youtube.com/watch?v=\(videoID)") == videoID else {
            completion([])
            return nil
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "videoID", value: videoID),
            URLQueryItem(name: "categories", value: #"["sponsor","selfpromo"]"#)
        ]
        guard let url = components?.url else {
            completion([])
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("seesee/0.4.1 (SponsorSkip)", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { data, response, _ in
            let segments: [SponsorSegment]
            if let data, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                segments = SponsorBlockPayload.segments(from: data)
            } else {
                segments = []
            }
            DispatchQueue.main.async {
                completion(segments)
            }
        }
        task.resume()
        return task
    }
}
