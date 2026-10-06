import Foundation

@main
struct SponsorSkipCheck {
    static func main() {
        checkVideoIDExtraction()
        checkSkipSession()
        checkPayloadParsing()
        checkHUDText()
        checkPreferenceDefaultOn()
        print("sponsor_skip_check=passed")
    }

    private static func checkVideoIDExtraction() {
        precondition(
            YouTubeVideoID.extract(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ",
            "watch?v= 形态必须抽出 11 位 videoID"
        )
        precondition(
            YouTubeVideoID.extract(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=45") == "dQw4w9WgXcQ",
            "带时间戳的 watch 链接仍抽出 videoID"
        )
        precondition(
            YouTubeVideoID.extract(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ",
            "youtu.be 短链必须抽出 videoID"
        )
        precondition(
            YouTubeVideoID.extract(from: "https://youtu.be/dQw4w9WgXcQ?t=30") == "dQw4w9WgXcQ",
            "带参数的 youtu.be 仍抽出 videoID"
        )
        precondition(
            YouTubeVideoID.extract(from: "http://m.youtube.com/watch?v=abcdefghijk") == "abcdefghijk",
            "移动站 host 也算 YouTube"
        )
        precondition(
            YouTubeVideoID.extract(from: "https://www.bilibili.com/video/BV1xx411c7mD") == nil,
            "非 YouTube 来源必须静默返回空"
        )
        precondition(
            YouTubeVideoID.extract(from: "https://www.youtube.com/watch?v=") == nil,
            "空 videoID 不得当成有效"
        )
        precondition(
            YouTubeVideoID.extract(from: "not a url") == nil,
            "无法解析的字符串返回空"
        )
    }

    private static func checkSkipSession() {
        var session = SponsorSkipSession()
        session.replaceSegments([
            SponsorSegment(start: 15, end: 60, category: "sponsor"),
            SponsorSegment(start: 200, end: 230, category: "selfpromo")
        ])

        precondition(session.consumeSkip(at: 14.99) == nil, "未进入区间不得跳")
        let first = session.consumeSkip(at: 15)
        precondition(first == SponsorSkipDecision(end: 60, skippedDuration: 45), "进入段头必须跳到段尾")
        precondition(session.consumeSkip(at: 20) == nil, "同一区间本次播放不得再跳")
        precondition(session.consumeSkip(at: 59.9) == nil, "仍停在已跳过区间内不得循环 seek")

        let second = session.consumeSkip(at: 200.5)
        precondition(
            second == SponsorSkipDecision(end: 230, skippedDuration: 29.5),
            "另一区间仍可跳一次"
        )
        precondition(session.consumeSkip(at: 210) == nil, "第二区间跳过后不得再跳")

        session.replaceSegments([
            SponsorSegment(start: 10, end: 40, category: "sponsor"),
            SponsorSegment(start: 35, end: 50, category: "selfpromo")
        ])
        let merged = session.consumeSkip(at: 12)
        precondition(
            merged == SponsorSkipDecision(end: 50, skippedDuration: 38),
            "相交区间应合并成一次跳到最远尾"
        )

        session.replaceSegments([
            SponsorSegment(start: 8, end: 8, category: "sponsor"),
            SponsorSegment(start: 9, end: 7, category: "sponsor")
        ])
        precondition(session.consumeSkip(at: 8) == nil, "零长度或反向区间必须丢掉")

        session.reset()
        precondition(session.consumeSkip(at: 15) == nil, "reset 后不得残留旧区间")
    }

    private static func checkPayloadParsing() {
        let json = """
        [
          {
            "category": "sponsor",
            "actionType": "skip",
            "segment": [15.0, 60.0]
          },
          {
            "category": "selfpromo",
            "actionType": "skip",
            "segment": [200, 230]
          },
          {
            "category": "sponsor",
            "actionType": "mute",
            "segment": [1, 2]
          },
          {
            "category": "intro",
            "actionType": "skip",
            "segment": [0, 8]
          }
        ]
        """.data(using: .utf8)!

        let segments = SponsorBlockPayload.segments(from: json)
        precondition(segments.count == 2, "mute 与 intro 不得当成跳过")
        precondition(segments[0] == SponsorSegment(start: 15, end: 60, category: "sponsor"))
        precondition(segments[1] == SponsorSegment(start: 200, end: 230, category: "selfpromo"))
        precondition(SponsorBlockPayload.segments(from: Data("not-json".utf8)).isEmpty, "坏 JSON 必须静默成空")
        precondition(SponsorBlockPayload.segments(from: Data("[]".utf8)).isEmpty)
    }

    private static func checkHUDText() {
        precondition(SponsorSkipMessage.text(skippedDuration: 45) == "已跳过赞助段 45 秒")
        precondition(SponsorSkipMessage.text(skippedDuration: 44.6) == "已跳过赞助段 45 秒")
        precondition(SponsorSkipMessage.text(skippedDuration: 0.4) == "已跳过赞助段 1 秒")
    }

    private static func checkPreferenceDefaultOn() {
        let suite = "SponsorSkipPreference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(SponsorSkipPreference.load(from: defaults), "未写过偏好时默认打开")
        SponsorSkipPreference.save(false, to: defaults)
        precondition(!SponsorSkipPreference.load(from: defaults), "关闭后必须读回关闭")
        SponsorSkipPreference.save(true, to: defaults)
        precondition(SponsorSkipPreference.load(from: defaults), "再次打开必须读回打开")
    }
}
