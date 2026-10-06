import Foundation

@main
struct ResumeModelCheck {
    static func main() throws {
        let sample = WatchItem(
            id: UUID(),
            urlString: "https://example.com/video",
            title: "Test",
            author: "",
            duration: 600,
            addedAt: Date(),
            watchedAt: nil,
            state: .ready,
            progress: 1,
            progressLabel: "Ready offline",
            localFilePath: nil,
            errorMessage: nil,
            playbackPosition: 123.5,
            chapters: [VideoChapter(title: "Intro", startTime: 0, endTime: 60)],
            thumbnailFilePath: nil,
            subtitleFilePath: nil
        )
        let encoded = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(WatchItem.self, from: encoded)
        precondition(decoded.playbackPosition == 123.5)
        precondition(decoded.resumablePosition == 123.5)
        precondition(decoded.availableChapters.first?.title == "Intro")

        var older = sample
        older.title = "Older"
        older.addedAt = Date(timeIntervalSince1970: 100)
        var newer = sample
        newer.title = "Newer"
        newer.addedAt = Date(timeIntervalSince1970: 200)
        precondition(QueueOrderPolicy.newestFirst([older, newer]).map(\.title) == ["Newer", "Older"])

        let chapterJSON = #"[{"title":"Setup","start_time":65.25,"end_time":120},{"title":"Intro","start_time":0,"end_time":65.25}]"#
        let chapters = ChapterMetadata.decode(json: chapterJSON)
        precondition(chapters?.map(\.title) == ["Intro", "Setup"])
        precondition(chapters?.last?.startTime == 65.25)

        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "playbackPosition")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let migrated = try JSONDecoder().decode(WatchItem.self, from: legacyData)
        precondition(migrated.playbackPosition == nil)

        if let queuePath = CommandLine.arguments.dropFirst().first,
           FileManager.default.fileExists(atPath: queuePath) {
            let queueData = try Data(contentsOf: URL(fileURLWithPath: queuePath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode([WatchItem].self, from: queueData)
        }

        // sourceName 展示映射
        func source(for url: String) -> String {
            WatchItem(
                id: UUID(),
                urlString: url,
                title: "t",
                author: "",
                duration: nil,
                addedAt: Date(),
                watchedAt: nil,
                state: .queued,
                progress: 0,
                progressLabel: "queued",
                localFilePath: nil,
                errorMessage: nil,
                playbackPosition: nil,
                chapters: nil,
                thumbnailFilePath: nil,
                subtitleFilePath: nil
            ).sourceName
        }
        precondition(source(for: "https://www.youtube.com/watch?v=abc") == "YouTube")
        precondition(source(for: "https://youtu.be/abc") == "YouTube")
        precondition(source(for: "https://x.com/user/status/1") == "X")
        precondition(source(for: "https://twitter.com/user/status/1") == "X")
        precondition(source(for: "https://www.bilibili.com/video/BV1GJ411x7h7") == "哔哩哔哩")
        precondition(source(for: "https://b23.tv/abcdef") == "哔哩哔哩")
        precondition(source(for: "https://www.xiaohongshu.com/explore/1") == "小红书")
        precondition(source(for: "https://xhslink.com/m/xyz") == "小红书")
        precondition(source(for: "https://www.vimeo.com/123") == "Vimeo")
        precondition(source(for: "https://vimeo.com/123") == "Vimeo")

        print("resume_model_check=passed")
    }
}
