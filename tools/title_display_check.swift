import Foundation

/// 标题怎么显示、X 视频的原标题怎么取、什么时候翻、作者中文标题什么时候用。纯逻辑，不联网。

nonisolated(unsafe) private var failures: [String] = []

private func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

private func item(original: String?, title: String = "旧标题", author: String = "", url: String = "https://www.youtube.com/watch?v=aqz-KE-bpKQ") -> WatchItem {
    var item = WatchItem(
        id: UUID(), urlString: url, title: title, author: author, duration: nil, addedAt: Date(),
        watchedAt: nil, state: .ready, progress: 1, progressLabel: "已下载", localFilePath: nil,
        errorMessage: nil, playbackPosition: nil, chapters: nil, thumbnailFilePath: nil, subtitleFilePath: nil
    )
    item.originalTitle = original
    return item
}

@main
struct TitleDisplayCheck {
    static func main() {
        // 1. 显示优先级：改名 > 译名 > 原标题；原标题放在下面一行，去掉开头的「作者 - 」。
        var video = item(original: "Blender - Big Buck Bunny 60fps 4K", author: "Blender")
        expect(video.titleDisplay == TitleDisplay(primary: "Big Buck Bunny 60fps 4K", secondary: nil, kind: .original),
               "只有原标题时主标题应是去掉作者前缀的原标题：\(video.titleDisplay)")
        video.setTranslatedTitle("大雄兔 60 帧 4K", source: .onDevice)
        expect(video.title == "大雄兔 60 帧 4K", "有译名时 title 应是译名：\(video.title)")
        expect(video.titleDisplay.secondary == "Big Buck Bunny 60fps 4K", "译名下面应是原标题：\(video.titleDisplay)")
        expect(video.rename(to: "我的兔子"), "改名应生效")
        expect(video.title == "我的兔子" && video.customTitle == "我的兔子", "改名后 title 应是改的名")
        video.setTranslatedTitle("作者给的中文名", source: .author)
        expect(video.title == "我的兔子", "译名换了也不覆盖改名：\(video.title)")
        expect(video.rename(to: "作者给的中文名"), "改回自动标题应生效")
        expect(video.customTitle == nil, "改成和自动标题一样时应清掉改名，以后跟着译名走")
        // 原标题换了，旧译名作废。
        video.setOriginalTitle("Another title")
        expect(video.translatedTitle == nil && video.title == "Another title", "原标题换了应清掉旧译名：\(video.title)")

        // 2. 旧条目：title 当原标题。
        var legacy = item(original: nil, title: "Old video")
        legacy.adoptLegacyTitle()
        expect(legacy.originalTitle == "Old video", "旧条目的 title 应记成原标题")

        // 3. X 视频：推文正文去掉链接后的第一句，太短接下一句；正文为空用「作者的视频」。
        expect(XPostTitle.title(postText: "This is the real headline. Second sentence here. https://t.co/abc", author: "Ann")
               == "This is the real headline.", "X 原标题应是第一句：\(XPostTitle.title(postText: "This is the real headline. Second sentence here.", author: "Ann"))")
        expect(XPostTitle.title(postText: "Wow! Look at this robot doing backflips https://t.co/x", author: "Ann")
               == "Wow! Look at this robot doing backflips", "第一句太短应接下一句：\(XPostTitle.title(postText: "Wow! Look at this robot doing backflips https://t.co/x", author: "Ann"))")
        expect(XPostTitle.title(postText: "https://t.co/onlylink", author: "Ann") == "Ann的视频", "正文只有链接时应用「作者的视频」")
        expect(XPostTitle.title(postText: "", author: "") == "推文里的视频", "没有作者也没有正文时应有兜底标题")
        var post = item(original: "x.com", author: "", url: "https://x.com/someone/status/1")
        post.applyMetadataTitle(title: "Ann - This is the real headline. Second sente…", postText: "This is the real headline. Second sentence here.", author: "Ann")
        expect(post.originalTitle == "This is the real headline.", "X 条目原标题应取推文第一句：\(post.originalTitle ?? "nil")")
        expect(post.postText == "This is the real headline. Second sentence here.", "X 条目应另存推文全文")
        // 正文缺失（yt-dlp 给 null）和空正文一样，用「作者的视频」，不用 yt-dlp 截断过的标题。
        var nullPost = item(original: "x.com", author: "", url: "https://x.com/ann/status/123456789")
        nullPost.applyMetadataTitle(title: "Ann - video", postText: nil, author: "Ann")
        nullPost.author = "Ann"
        expect(nullPost.titleDisplay.primary == "Ann的视频", "X 正文为 null 时应用「作者的视频」：\(nullPost.titleDisplay.primary)")
        post.applyMetadataTitle(title: "", postText: "Hyper-motivation &amp; addiction = \u{201c}close\u{201d} states. More.", author: "Ann")
        expect(post.originalTitle == "Hyper-motivation & addiction = \u{201c}close\u{201d} states.", "推文里的 &amp; 应还原成 &：\(post.originalTitle ?? "nil")")

        // 4. 什么时候翻：中文不翻，没有文字不翻；源语言不为空。
        expect(!TitleLanguage.needsTranslation("我在旧版本里改过的名字"), "简体中文不翻")
        expect(!TitleLanguage.needsTranslation("繁體中文的標題在這裡"), "繁体中文不翻")
        expect(!TitleLanguage.needsTranslation("2024 - 01"), "没有文字的不翻")
        expect(TitleLanguage.needsTranslation("Big Buck Bunny 60fps 4K"), "英文要翻")
        expect(TitleLanguage.sourceLanguage(for: "Big Buck Bunny", hint: nil) == "en", "英文标题源语言应是 en：\(TitleLanguage.sourceLanguage(for: "Big Buck Bunny", hint: nil))")
        expect(TitleLanguage.sourceLanguage(for: "日本語のタイトルです", hint: "ja") == "ja", "日文标题源语言应是 ja")
        expect(!TitleLanguage.sourceLanguage(for: "123", hint: "und").isEmpty, "源语言不能为空")

        // 5. 作者中文标题：是中文、和原标题不同、原标题不是中文时才用。
        expect(AuthorTitle.accepts(localized: "如何制作一部开放电影", original: "How to make an open movie"), "作者中文标题应被采用")
        expect(!AuthorTitle.accepts(localized: "How to make an open movie", original: "How to make an open movie"), "和原标题一样的不用")
        expect(!AuthorTitle.accepts(localized: "中文标题", original: "原本就是中文"), "原标题本身是中文时不用")

        if failures.isEmpty {
            print("title_display_check=passed（显示优先级、改名不被覆盖、旧条目迁移、X 原标题、何时翻译、作者中文标题）")
        } else {
            failures.forEach { print("失败：\($0)") }
            exit(1)
        }
    }
}
