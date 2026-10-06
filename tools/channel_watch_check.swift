import Foundation

@main
struct ChannelWatchCheck {
    static func main() {
        checkSubscriptionDetection()
        checkCanonicalSubscriptionURL()
        checkListingParse()
        checkSelectNewEntries()
        checkBaselinePolicy()
        checkSubscriptionFile()
        print("channel_watch_check=passed")
    }

    private static func checkSubscriptionDetection() {
        let subscriptions = [
            "https://www.youtube.com/@veritasium",
            "https://www.youtube.com/@veritasium/videos",
            "https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA",
            "https://www.youtube.com/c/Veritasium",
            "https://www.youtube.com/user/1veritasium",
            "https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf",
            "http://youtube.com/@foo",
            "https://space.bilibili.com/123456",
            "https://space.bilibili.com/123456/video",
            "https://www.bilibili.com/medialist/play/ml123456",
            "https://www.bilibili.com/medialist/detail/ml123456"
        ]
        for value in subscriptions {
            let url = URL(string: value)!
            precondition(ChannelLink.isSubscription(url), "should treat as subscription: \(value)")
        }

        let videos = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLxxx",
            "https://youtu.be/dQw4w9WgXcQ",
            "https://www.youtube.com/shorts/abc12345678",
            "https://www.bilibili.com/video/BV1xx411c7mD",
            "https://x.com/user/status/1234567890",
            "https://www.youtube.com/results?search_query=hello",
            "https://www.youtube.com/feed/subscriptions",
            "https://www.youtube.com/live/dQw4w9WgXcQ"
        ]
        for value in videos {
            let url = URL(string: value)!
            precondition(!ChannelLink.isSubscription(url), "should treat as video: \(value)")
        }
    }

    private static func checkCanonicalSubscriptionURL() {
        let handle = URL(string: "https://www.youtube.com/@veritasium/videos?feature=share")!
        precondition(
            ChannelLink.canonicalString(for: handle) == "https://www.youtube.com/@veritasium",
            ChannelLink.canonicalString(for: handle)
        )

        let playlist = URL(string: "https://www.youtube.com/playlist?list=PLabc&si=tracker")!
        precondition(
            ChannelLink.canonicalString(for: playlist) == "https://www.youtube.com/playlist?list=PLabc",
            ChannelLink.canonicalString(for: playlist)
        )

        let channel = URL(string: "https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA/videos")!
        precondition(
            ChannelLink.canonicalString(for: channel) == "https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA",
            ChannelLink.canonicalString(for: channel)
        )

        precondition(ChannelLink.displayTitle(for: handle) == "@veritasium")
        precondition(ChannelLink.displayTitle(for: playlist) == "PLabc")
        precondition(ChannelLink.usesPlaylistOrder(playlist))
        precondition(!ChannelLink.usesPlaylistOrder(handle))
    }

    private static func checkListingParse() {
        let source = URL(string: "https://www.youtube.com/@veritasium")!
        let output = """
        [youtube:tab] Extracting URL: https://www.youtube.com/@veritasium
        abcdefghijk|First Video
        lmnopqrstuv|Second Video|https://www.youtube.com/watch?v=lmnopqrstuv
        NA|skip me
        BV1xx411c7mD|B站标题|https://www.bilibili.com/video/BV1xx411c7mD?spm_id_from=333.337
        """
        let entries = PlaylistListing.parse(output, sourceURL: source)
        precondition(entries.count == 3, "parsed \(entries.count): \(entries.map(\.id))")
        precondition(entries[0].id == "abcdefghijk")
        precondition(entries[0].title == "First Video")
        precondition(entries[0].url.absoluteString == "https://www.youtube.com/watch?v=abcdefghijk")
        precondition(entries[1].url.absoluteString == "https://www.youtube.com/watch?v=lmnopqrstuv")
        precondition(entries[2].id == "BV1xx411c7mD")
        precondition(entries[2].url.absoluteString == "https://www.bilibili.com/video/BV1xx411c7mD")
    }

    private static func checkSelectNewEntries() {
        let source = URL(string: "https://www.youtube.com/@veritasium")!
        let listing = PlaylistListing.parse("""
        aaa11111111|One
        bbb22222222|Two
        ccc33333333|Three
        ddd44444444|Four
        eee55555555|Five
        """, sourceURL: source)

        let allNew = PlaylistListing.newEntries(
            from: listing,
            existingURLStrings: [],
            maximumAdditions: 3
        )
        precondition(allNew.map(\.id) == ["aaa11111111", "bbb22222222", "ccc33333333"])

        let someExisting = PlaylistListing.newEntries(
            from: listing,
            existingURLStrings: [
                "https://www.youtube.com/watch?v=aaa11111111",
                "https://www.youtube.com/watch?v=ccc33333333"
            ],
            maximumAdditions: 3
        )
        precondition(someExisting.map(\.id) == ["bbb22222222", "ddd44444444", "eee55555555"])

        let allKnown = PlaylistListing.newEntries(
            from: listing,
            existingURLStrings: Set(listing.map { URLIntake.canonicalString(for: $0.url) }),
            maximumAdditions: 3
        )
        precondition(allKnown.isEmpty)
    }

    /// 首次订阅只记清单不入队；之后只入队基线之外的新视频，每次最多 3 条，没轮到的留到下次。
    private static func checkBaselinePolicy() {
        let source = URL(string: "https://www.youtube.com/@veritasium")!
        let first = PlaylistListing.parse("""
        aaa11111111|One
        bbb22222222|Two
        ccc33333333|Three
        """, sourceURL: source)
        let baseline = ChannelWatchPolicy.plan(listing: first, known: [], existingURLStrings: [])
        precondition(baseline.toEnqueue.isEmpty, "首次订阅不得入队旧片")
        precondition(baseline.knownURLStrings == first.map { URLIntake.canonicalString(for: $0.url) })

        let again = ChannelWatchPolicy.plan(listing: first, known: baseline.knownURLStrings, existingURLStrings: [])
        precondition(again.toEnqueue.isEmpty, "清单没变就没有新片")
        precondition(again.knownURLStrings == baseline.knownURLStrings)

        let later = PlaylistListing.parse("""
        eee55555555|Five
        ddd44444444|Four
        aaa11111111|One
        bbb22222222|Two
        """, sourceURL: source)
        let update = ChannelWatchPolicy.plan(listing: later, known: baseline.knownURLStrings, existingURLStrings: [])
        precondition(update.toEnqueue.map(\.id) == ["eee55555555", "ddd44444444"], "只入队基线之外的新片，按清单顺序")
        precondition(Set(update.knownURLStrings).count == 5, "入队的记入基线")

        let inQueue = ChannelWatchPolicy.plan(
            listing: later,
            known: baseline.knownURLStrings,
            existingURLStrings: ["https://www.youtube.com/watch?v=eee55555555"]
        )
        precondition(inQueue.toEnqueue.map(\.id) == ["ddd44444444"], "已在待播清单里的不重复入队")
        precondition(inQueue.knownURLStrings.contains("https://www.youtube.com/watch?v=eee55555555"), "已在清单里的记入基线")

        let burst = PlaylistListing.parse("""
        n1111111111|N1
        n2222222222|N2
        n3333333333|N3
        n4444444444|N4
        n5555555555|N5
        aaa11111111|One
        """, sourceURL: source)
        let capped = ChannelWatchPolicy.plan(listing: burst, known: baseline.knownURLStrings, existingURLStrings: [], maximumAdditions: 3)
        precondition(capped.toEnqueue.map(\.id) == ["n1111111111", "n2222222222", "n3333333333"], "每次最多 3 条")
        precondition(!capped.knownURLStrings.contains("https://www.youtube.com/watch?v=n4444444444"), "没轮到的不记基线，下次再来")
        let next = ChannelWatchPolicy.plan(listing: burst, known: capped.knownURLStrings, existingURLStrings: [], maximumAdditions: 3)
        precondition(next.toEnqueue.map(\.id) == ["n4444444444", "n5555555555"], "下次补上剩余新片")
    }

    private static func checkSubscriptionFile() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-watch-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appendingPathComponent("subscriptions.json")
        precondition(ChannelSubscriptionFile.load(from: file).isEmpty)

        let original = [
            ChannelSubscription(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                urlString: "https://www.youtube.com/@veritasium",
                title: "@veritasium",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastCheckedAt: Date(timeIntervalSince1970: 1_700_000_400)
            )
        ]
        ChannelSubscriptionFile.save(original, to: file)
        let loaded = ChannelSubscriptionFile.load(from: file)
        precondition(loaded.count == 1)
        precondition(loaded[0].id == original[0].id)
        precondition(loaded[0].urlString == original[0].urlString)
        precondition(loaded[0].title == original[0].title)
        precondition(loaded[0].addedAt.timeIntervalSince1970 == 1_700_000_000)
        precondition(loaded[0].lastCheckedAt?.timeIntervalSince1970 == 1_700_000_400)
        precondition(loaded[0].knownURLStrings.isEmpty)

        var withBaseline = original
        withBaseline[0].knownURLStrings = ["https://www.youtube.com/watch?v=aaa11111111"]
        ChannelSubscriptionFile.save(withBaseline, to: file)
        precondition(ChannelSubscriptionFile.load(from: file)[0].knownURLStrings == ["https://www.youtube.com/watch?v=aaa11111111"], "基线随文件保存")

        let legacy = """
        [{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","urlString":"https://www.youtube.com/@veritasium","title":"@veritasium","addedAt":"2023-11-14T22:13:20Z"}]
        """
        try! legacy.data(using: .utf8)!.write(to: file)
        let migrated = ChannelSubscriptionFile.load(from: file)
        precondition(migrated.count == 1 && migrated[0].knownURLStrings.isEmpty, "旧文件没有基线字段也能读")
    }
}
