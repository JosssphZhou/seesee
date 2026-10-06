import Foundation

/// 右栏目录只列视频自带的章节（来自视频元数据），标题和时间原样显示。
enum DigestTOCCopy {
    static func collapsedTitle(chapterCount: Int, duration: Double?) -> String {
        guard let duration, duration.isFinite, duration > 0 else {
            return "目录 · \(chapterCount) 章"
        }
        return "目录 · \(chapterCount) 章 · \(DigestTimecode.format(duration))"
    }
}

enum DigestTOCChapters {
    /// 能列进目录的章节：按开始时间排序，去掉时间无效的。
    static func listed(_ chapters: [VideoChapter]) -> [VideoChapter] {
        chapters
            .filter { $0.startTime.isFinite && $0.startTime >= 0 }
            .sorted { $0.startTime < $1.startTime }
    }

    /// 当前章：开始时间不晚于播放位置的最后一章；返回它在 `chapters` 里的下标。
    static func currentIndex(at time: Double, in chapters: [VideoChapter]) -> Int? {
        guard time.isFinite, !chapters.isEmpty else { return nil }
        var current: Int?
        var currentStart = -Double.infinity
        for (index, chapter) in chapters.enumerated() where chapter.startTime <= time && chapter.startTime >= currentStart {
            current = index
            currentStart = chapter.startTime
        }
        return current
    }
}

enum DigestTimecode {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%d:%02d", minutes, remaining)
    }
}
