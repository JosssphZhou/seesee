import AppKit

enum PlaybackKeyboardAction: Equatable {
    case passThrough
    case insertLiteralSpace
    case togglePlayback
    case toggleFullscreen
    case exitFullscreen
    case skip(Double)
    case adjustRate(Double)
    case pasteURL
    case resignTextFocus
}

enum PlaybackKeyboardRouting {
    private static let shortcutModifiers: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift
    ]

    static func window(for event: NSEvent) -> NSWindow? {
        event.window ?? NSApp.keyWindow
    }

    static func action(
        in window: NSWindow?,
        keyCode: UInt16,
        character: String?,
        modifiers: NSEvent.ModifierFlags,
        hasActivePlayer: Bool
    ) -> PlaybackKeyboardAction {
        action(
            isEditingText: isEditingText(in: window),
            keyCode: keyCode,
            character: character,
            modifiers: modifiers,
            hasActivePlayer: hasActivePlayer
        )
    }

    static func action(
        isEditingText: Bool,
        keyCode: UInt16,
        character: String?,
        modifiers: NSEvent.ModifierFlags,
        hasActivePlayer: Bool
    ) -> PlaybackKeyboardAction {
        let mods = modifiers.intersection(shortcutModifiers)

        if isEditingText {
            if keyCode == 53, mods.isEmpty {
                return .resignTextFocus
            }
            if keyCode == 49, mods.isEmpty {
                return .insertLiteralSpace
            }
            return .passThrough
        }

        if mods == .command, character?.lowercased() == "v" {
            return .pasteURL
        }

        guard mods.isEmpty else { return .passThrough }

        if keyCode == 53 {
            return .exitFullscreen
        }

        guard hasActivePlayer else { return .passThrough }

        if keyCode == 49 {
            return .togglePlayback
        }
        if character?.lowercased() == "f" {
            return .toggleFullscreen
        }

        switch keyCode {
        case 123:
            return .skip(-10)
        case 124:
            return .skip(10)
        case 126:
            return .adjustRate(0.1)
        case 125:
            return .adjustRate(-0.1)
        default:
            return .passThrough
        }
    }

    static func isEditingText(in window: NSWindow?) -> Bool {
        isEditingText(firstResponder: window?.firstResponder)
    }

    static func isEditingText(firstResponder: NSResponder?) -> Bool {
        var current = firstResponder
        while let responder = current {
            if let view = responder as? NSView, isEditableTextSurface(view) {
                return true
            }
            if let control = responder as? NSControl, control.currentEditor() != nil {
                return true
            }
            if isTextInputClassName((responder as NSObject).className) {
                return true
            }
            current = responder.nextResponder
        }
        return false
    }

    static func isEditableTextSurface(_ view: NSView) -> Bool {
        if let textView = view as? NSTextView {
            return textView.isEditable
        }
        if let textField = view as? NSTextField {
            return textField.isEditable
        }
        return false
    }

    @discardableResult
    static func insertPlainText(_ text: String, in window: NSWindow?) -> Bool {
        guard isEditingText(in: window) else { return false }
        guard let responder = window?.firstResponder else { return false }
        if let textView = responder as? NSTextView, textView.isEditable {
            let range = textView.selectedRange()
            textView.insertText(text, replacementRange: range)
            return true
        }
        if let client = responder as? NSTextInputClient {
            client.insertText(text, replacementRange: client.selectedRange())
            return true
        }
        return false
    }

    static func isTextInputClassName(_ className: String) -> Bool {
        if className.hasPrefix("NSText") {
            return false
        }
        return className.contains("TextField")
            || className.contains("TextEditor")
            || className.contains("FieldEditor")
    }
}
