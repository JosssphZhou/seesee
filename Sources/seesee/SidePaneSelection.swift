import Foundation

enum SidePaneMode: String {
    case lyrics

    /// 旧版页签键一律落到单页字幕书。
    static func fromPersisted(_ raw: String) -> SidePaneMode {
        _ = raw
        return .lyrics
    }
}

enum SidePaneSelection {
    static func openingMode(hasChapters _: Bool) -> SidePaneMode {
        .lyrics
    }

    static func resolvedMode(
        preferred _: SidePaneMode,
        hasChapters _: Bool,
        hasSubtitles _: Bool
    ) -> SidePaneMode {
        .lyrics
    }

    static func recomputedMode(
        current _: SidePaneMode,
        hasChapters _: Bool,
        userHasManuallySwitched _: Bool
    ) -> SidePaneMode {
        .lyrics
    }

    static func visibleTitle(for _: SidePaneMode) -> String {
        "字幕"
    }
}
