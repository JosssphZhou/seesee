import AppKit

enum DigestKeyboardAction: Equatable {
    case passThrough
    case moveFocus(Int)
    case jump
}

/// 字幕书快捷键。字幕书可用且焦点不在输入框时生效：
/// [ / ] 移句、回车跳播放。
/// 上下方向键始终调速度；空格、左右方向键、f 仍交给播放。
enum DigestKeyboardRouting {
    private static let shortcutModifiers: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift
    ]

    static func action(
        isEditingText: Bool,
        bookAvailable: Bool,
        keyCode: UInt16,
        character: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> DigestKeyboardAction {
        if isEditingText { return .passThrough }
        guard bookAvailable else { return .passThrough }

        let mods = modifiers.intersection(shortcutModifiers)
        guard mods.isEmpty else { return .passThrough }

        if keyCode == 36 || keyCode == 76 {
            return .jump
        }

        switch character {
        case "[":
            return .moveFocus(-1)
        case "]":
            return .moveFocus(1)
        default:
            return .passThrough
        }
    }
}

enum DigestKeyboardFocus {
    static func moving(
        from focused: Int?,
        visible: [Int],
        delta: Int,
        playing: Int?
    ) -> Int? {
        guard !visible.isEmpty else { return nil }
        let start: Int
        if let focused, let index = visible.firstIndex(of: focused) {
            start = index
        } else if let playing, let index = visible.firstIndex(of: playing) {
            start = index
        } else {
            start = delta > 0 ? 0 : visible.count - 1
        }
        let next = min(max(start + delta, 0), visible.count - 1)
        return visible[next]
    }

    static func resolved(focused: Int?, visible: [Int], playing: Int?) -> Int? {
        if let focused, visible.contains(focused) { return focused }
        if let playing, visible.contains(playing) { return playing }
        return visible.first
    }

    static func afterVideoChange() -> Int? { nil }
}

enum SeeseeKeyDispatch {
    enum Decision: Equatable {
        case digest(DigestKeyboardAction)
        case playback(PlaybackKeyboardAction)
    }

    static func decide(
        isEditingText: Bool,
        bookAvailable: Bool,
        hasActivePlayer: Bool,
        keyCode: UInt16,
        character: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Decision {
        let digest = DigestKeyboardRouting.action(
            isEditingText: isEditingText,
            bookAvailable: bookAvailable,
            keyCode: keyCode,
            character: character,
            modifiers: modifiers
        )
        if digest != .passThrough {
            return .digest(digest)
        }
        return .playback(
            PlaybackKeyboardRouting.action(
                isEditingText: isEditingText,
                keyCode: keyCode,
                character: character,
                modifiers: modifiers,
                hasActivePlayer: hasActivePlayer
            )
        )
    }
}

extension Notification.Name {
    static let seeseeDigestKeyboard = Notification.Name("SeeseeDigestKeyboard")
}

final class DigestCommandCenter {
    static let shared = DigestCommandCenter()

    var bookAvailable = false

    private init() {}

    @discardableResult
    func perform(_ action: DigestKeyboardAction) -> Bool {
        guard bookAvailable, action != .passThrough else { return false }
        NotificationCenter.default.post(name: .seeseeDigestKeyboard, object: action)
        return true
    }
}
