import Foundation

struct ChannelSubscription: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var urlString: String
    var title: String
    var addedAt: Date
    var lastCheckedAt: Date?
    /// 基线：订阅当时清单里已有的视频（规范化 URL），只有之后新出现的才入队。空表示还没建基线。
    var knownURLStrings: [String]

    init(
        id: UUID,
        urlString: String,
        title: String,
        addedAt: Date,
        lastCheckedAt: Date?,
        knownURLStrings: [String] = []
    ) {
        self.id = id
        self.urlString = urlString
        self.title = title
        self.addedAt = addedAt
        self.lastCheckedAt = lastCheckedAt
        self.knownURLStrings = knownURLStrings
    }

    enum CodingKeys: String, CodingKey {
        case id, urlString, title, addedAt, lastCheckedAt, knownURLStrings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        urlString = try container.decode(String.self, forKey: .urlString)
        title = try container.decode(String.self, forKey: .title)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        knownURLStrings = try container.decodeIfPresent([String].self, forKey: .knownURLStrings) ?? []
    }
}

enum ChannelSubscriptionFile {
    static func load(from file: URL) -> [ChannelSubscription] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChannelSubscription].self, from: data)) ?? []
    }

    static func save(_ items: [ChannelSubscription], to file: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}
