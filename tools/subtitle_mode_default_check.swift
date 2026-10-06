import Foundation

// 字幕档位默认值的检查：视频没记过档位时，老用户照旧全局开关，新用户默认双语。
// 用检查程序自己的偏好设置域，开始前清空，结束后删掉。在新用户默认关的旧代码上，第 3 条失败。

@main
struct SubtitleModeDefaultCheck {
    static let modeKey = "subtitleModePerVideo"
    static let legacyKey = "subtitlesEnabled"

    static func main() {
        let defaults = UserDefaults.standard
        let domain = ProcessInfo.processInfo.processName
        // 偏好设置进程会在检查退出后留下一个同名的空偏好文件，名字固定，不会越积越多。
        func cleanUp() {
            defaults.removePersistentDomain(forName: domain)
        }
        cleanUp()
        defer { cleanUp() }

        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func reset() {
            defaults.removeObject(forKey: modeKey)
            defaults.removeObject(forKey: legacyKey)
        }
        let video = UUID()

        // 1. 视频记过档位：照记的来，不看旧全局开关。
        reset()
        defaults.set(true, forKey: legacyKey)
        SubtitleModeStore.set(.translationOnly, for: video)
        expect(SubtitleModeStore.mode(for: video) == .translationOnly, "记过档位的视频应照记的档位")
        SubtitleModeStore.set(.off, for: video)
        expect(SubtitleModeStore.mode(for: video) == .off, "记过「关」的视频应保持关")

        // 2. 没记过、旧全局开关存在：照旧开关来，明确关掉的也保持关。
        reset()
        defaults.set(true, forKey: legacyKey)
        expect(SubtitleModeStore.mode(for: video) == .bilingual, "旧全局开关为开时，没记过档位的视频应是双语")
        defaults.set(false, forKey: legacyKey)
        expect(SubtitleModeStore.mode(for: video) == .off, "旧全局开关明确为关时，没记过档位的视频应保持关")

        // 3. 没记过、旧全局开关不存在（新用户）：双语。
        reset()
        expect(SubtitleModeStore.mode(for: video) == .bilingual, "新用户没记过档位的视频应默认双语")

        if failures.isEmpty {
            print("subtitle_mode_default_check=passed")
        } else {
            failures.forEach { print("失败：\($0)") }
            cleanUp()
            exit(1)
        }
    }
}
