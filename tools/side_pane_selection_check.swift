import Foundation

@main
struct SidePaneSelectionCheck {
    static func main() {
        precondition(SidePaneSelection.openingMode(hasChapters: true) == .lyrics)
        precondition(SidePaneSelection.openingMode(hasChapters: false) == .lyrics)

        precondition(
            SidePaneSelection.resolvedMode(
                preferred: .lyrics,
                hasChapters: false,
                hasSubtitles: true
            ) == .lyrics
        )
        precondition(
            SidePaneSelection.resolvedMode(
                preferred: .lyrics,
                hasChapters: true,
                hasSubtitles: false
            ) == .lyrics
        )

        precondition(SidePaneSelection.visibleTitle(for: .lyrics) == "字幕")
        precondition(SidePaneSelection.visibleTitle(for: .lyrics) != "歌词")

        precondition(SidePaneMode.fromPersisted("chapters") == .lyrics, "旧章节页签须落到单页字幕书")
        precondition(SidePaneMode.fromPersisted("overview") == .lyrics, "旧总览页签须落到单页字幕书")
        precondition(SidePaneMode.fromPersisted("notes") == .lyrics, "旧笔记页签须落到单页字幕书")
        precondition(SidePaneMode.fromPersisted("lyrics") == .lyrics)
        precondition(SidePaneMode.fromPersisted("unknown") == .lyrics)

        precondition(
            SidePaneSelection.recomputedMode(
                current: .lyrics,
                hasChapters: true,
                userHasManuallySwitched: false
            ) == .lyrics,
            "单页形态下章节落地不得切走字幕书"
        )
        precondition(
            SidePaneSelection.recomputedMode(
                current: .lyrics,
                hasChapters: false,
                userHasManuallySwitched: true
            ) == .lyrics
        )

        print("side_pane_selection_check=passed")
    }
}
