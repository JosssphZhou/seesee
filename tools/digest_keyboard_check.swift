import AppKit
import Foundation

@main
struct DigestKeyboardCheck {
    static func main() {
        assertSchemeWhenBookAvailable()
        assertSchemeWhenBookUnavailable()
        assertEditingDoesNotIntercept()
        assertPlaybackKeysStillReachPlayer()
        assertDispatchPrefersDigestThenPlayback()
        assertFocusMovesAmongVisibleCues()
        assertFocusStartsFromPlayingCue()
        assertFocusClampsAtEnds()
        assertFocusAfterVideoChange()
        print("digest_keyboard_check=passed")
    }

    private static func assertSchemeWhenBookAvailable() {
        precondition(route(character: "[", keyCode: 33) == .moveFocus(-1), "[ 必须移到上一句")
        precondition(route(character: "]", keyCode: 30) == .moveFocus(1), "] 必须移到下一句")
        precondition(route(keyCode: 36) == .jump, "回车必须跳到焦点句播放")
        precondition(route(keyCode: 76) == .jump, "小键盘回车必须同样跳播放")
        precondition(route(character: "e", keyCode: 14) == .passThrough, "解释已删除，e 不得再被字幕书占用")
        precondition(route(character: "E", keyCode: 14) == .passThrough, "解释已删除，大写 E 同样放行")
        for character in ["h", "H", "l", "L"] {
            precondition(route(character: character, keyCode: 0) == .passThrough, "\(character) 不得被字幕书占用")
        }
        precondition(route(keyCode: 126) == .passThrough, "上方向键不得占用，必须留给调速")
        precondition(route(keyCode: 125) == .passThrough, "下方向键不得占用，必须留给调速")
    }

    private static func assertSchemeWhenBookUnavailable() {
        for keyCode: UInt16 in [126, 125, 36, 76] {
            precondition(
                route(bookAvailable: false, keyCode: keyCode) == .passThrough,
                "没有字幕书时方向键与回车必须放行，交给播放快捷键"
            )
        }
        for character in ["e", "h", "l", "[", "]"] {
            precondition(
                route(bookAvailable: false, character: character, keyCode: 0) == .passThrough,
                "没有字幕书时 \(character) 必须放行"
            )
        }
    }

    private static func assertEditingDoesNotIntercept() {
        for keyCode: UInt16 in [126, 125, 36, 123, 124] {
            precondition(
                route(isEditingText: true, keyCode: keyCode) == .passThrough,
                "搜索框输入中，方向键与回车不得拦截"
            )
        }
        for character in ["e", "h", "l", "a", "f", "[", "]"] {
            precondition(
                route(isEditingText: true, character: character, keyCode: 0) == .passThrough,
                "输入中 \(character) 必须留给文字"
            )
        }
    }

    private static func assertPlaybackKeysStillReachPlayer() {
        precondition(route(keyCode: 123) == .passThrough, "左方向键必须留给快退")
        precondition(route(keyCode: 124) == .passThrough, "右方向键必须留给快进")
        precondition(route(keyCode: 126) == .passThrough, "上方向键必须留给调速")
        precondition(route(keyCode: 125) == .passThrough, "下方向键必须留给调速")
        precondition(route(keyCode: 49) == .passThrough, "空格必须留给播放")
        precondition(route(character: "a", keyCode: 0) == .passThrough, "a 不是字幕书快捷键，必须放行")
        precondition(route(character: "f", keyCode: 3) == .passThrough, "f 必须留给全屏")
        precondition(
            route(character: "e", keyCode: 14, modifiers: .command) == .passThrough,
            "带修饰键的 e 不得当解释"
        )
        precondition(
            route(character: "[", keyCode: 33, modifiers: .shift) == .passThrough,
            "Shift-[ 不得移句"
        )
    }

    private static func assertDispatchPrefersDigestThenPlayback() {
        precondition(
            dispatch(character: "[", keyCode: 33) == .digest(.moveFocus(-1)),
            "字幕书可用时 [ 必须走上一句"
        )
        precondition(
            dispatch(character: "]", keyCode: 30) == .digest(.moveFocus(1)),
            "字幕书可用时 ] 必须走下一句"
        )
        precondition(
            dispatch(keyCode: 126) == .playback(.adjustRate(0.1)),
            "字幕书可用时上方向键必须仍加快播放速度"
        )
        precondition(
            dispatch(keyCode: 125) == .playback(.adjustRate(-0.1)),
            "字幕书可用时下方向键必须仍减慢播放速度"
        )
        precondition(
            dispatch(bookAvailable: false, keyCode: 126) == .playback(.adjustRate(0.1)),
            "字幕书不可用时上方向键必须仍加快播放速度"
        )
        precondition(
            dispatch(bookAvailable: false, keyCode: 125) == .playback(.adjustRate(-0.1)),
            "字幕书不可用时下方向键必须仍减慢播放速度"
        )
        precondition(
            dispatch(keyCode: 123) == .playback(.skip(-10)),
            "左方向键即使在字幕书里也必须快退"
        )
        precondition(
            dispatch(keyCode: 49) == .playback(.togglePlayback),
            "空格即使在字幕书里也必须切换播放"
        )
        precondition(
            dispatch(character: "e", keyCode: 14) == .playback(.passThrough),
            "解释已删除，e 在字幕书里也不得触发任何动作"
        )
        precondition(
            dispatch(character: "a", keyCode: 0) == .playback(.passThrough),
            "看时问答已删除，a 不得触发任何动作"
        )
        precondition(
            dispatch(isEditingText: true, keyCode: 126) == .playback(.passThrough),
            "输入中上方向键必须交给光标"
        )
        precondition(
            dispatch(isEditingText: true, character: "[", keyCode: 33) == .playback(.passThrough),
            "输入中 [ 必须留给文字"
        )
        precondition(
            dispatch(isEditingText: true, keyCode: 49) == .playback(.insertLiteralSpace)
        )
        precondition(
            dispatch(isEditingText: true, character: "h", keyCode: 4) == .playback(.passThrough)
        )
    }

    private static func assertFocusMovesAmongVisibleCues() {
        let visible = [0, 2, 5]
        precondition(
            DigestKeyboardFocus.moving(from: 2, visible: visible, delta: 1, playing: 0) == 5
        )
        precondition(
            DigestKeyboardFocus.moving(from: 2, visible: visible, delta: -1, playing: 0) == 0
        )
    }

    private static func assertFocusStartsFromPlayingCue() {
        let visible = [0, 1, 2, 3]
        precondition(
            DigestKeyboardFocus.moving(from: nil, visible: visible, delta: 1, playing: 1) == 2,
            "尚无焦点时，应从当前播放句往下走"
        )
        precondition(
            DigestKeyboardFocus.moving(from: nil, visible: visible, delta: -1, playing: 1) == 0,
            "尚无焦点时，应从当前播放句往上走"
        )
        precondition(
            DigestKeyboardFocus.resolved(focused: nil, visible: visible, playing: 2) == 2,
            "回车在尚无焦点时应落在当前播放句"
        )
        precondition(
            DigestKeyboardFocus.resolved(focused: 3, visible: visible, playing: 0) == 3
        )
    }

    private static func assertFocusClampsAtEnds() {
        let visible = [1, 4, 8]
        precondition(
            DigestKeyboardFocus.moving(from: 1, visible: visible, delta: -1, playing: 4) == 1,
            "到顶不得循环"
        )
        precondition(
            DigestKeyboardFocus.moving(from: 8, visible: visible, delta: 1, playing: 4) == 8,
            "到底不得循环"
        )
        precondition(DigestKeyboardFocus.moving(from: nil, visible: [], delta: 1, playing: 0) == nil)
    }

    private static func assertFocusAfterVideoChange() {
        precondition(DigestKeyboardFocus.afterVideoChange() == nil, "换视频必须丢掉上一本的句焦点")
        precondition(
            DigestKeyboardFocus.resolved(focused: 9, visible: [0, 1], playing: 0) == 0,
            "焦点不在可见列表时回落到当前播放句"
        )
    }

    private static func route(
        isEditingText: Bool = false,
        bookAvailable: Bool = true,
        character: String? = nil,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> DigestKeyboardAction {
        DigestKeyboardRouting.action(
            isEditingText: isEditingText,
            bookAvailable: bookAvailable,
            keyCode: keyCode,
            character: character,
            modifiers: modifiers
        )
    }

    private static func dispatch(
        isEditingText: Bool = false,
        bookAvailable: Bool = true,
        character: String? = nil,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> SeeseeKeyDispatch.Decision {
        SeeseeKeyDispatch.decide(
            isEditingText: isEditingText,
            bookAvailable: bookAvailable,
            hasActivePlayer: true,
            keyCode: keyCode,
            character: character,
            modifiers: modifiers
        )
    }
}
