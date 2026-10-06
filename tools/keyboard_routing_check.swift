import AppKit
import Foundation

@main
struct KeyboardRoutingCheck {
    static func main() {
        _ = NSApplication.shared

        assertEditingDetection()
        assertIdlePlaybackShortcuts()
        assertEditingPassesText()
        assertEditingSpaceIsPassedThrough()
        assertModifierSpaceIsPassedThrough()
        assertSpacePassesWhenReceivingTextInput()
        assertLeftoverTextDoesNotBlockShortcuts()
        assertModifierCombinations()
        assertMissingPlayer()
        assertWindowFocusControllerClearsInitialResponder()
        assertEscapeResignCarriesReason()
        assertEscapeThenClickOtherFieldCommitsTitle()

        print("keyboard_routing_check=passed")
    }

    private static func assertEditingDetection() {
        precondition(
            !PlaybackKeyboardRouting.isEditingText(firstResponder: nil),
            "无第一响应者时不得当作编辑态"
        )

        let editableView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        editableView.isEditable = true
        precondition(
            PlaybackKeyboardRouting.isEditingText(firstResponder: editableView),
            "可编辑文本视图必须识别为编辑态"
        )

        editableView.isEditable = false
        precondition(
            !PlaybackKeyboardRouting.isEditingText(firstResponder: editableView),
            "只读文本视图不得识别为编辑态"
        )

        let field = NSTextField(string: "hello world")
        field.isEditable = true
        precondition(
            PlaybackKeyboardRouting.isEditingText(firstResponder: field),
            "可编辑输入框必须识别为编辑态"
        )

        field.isEditable = false
        precondition(
            !PlaybackKeyboardRouting.isEditingText(firstResponder: field),
            "只读输入框不得识别为编辑态"
        )
        precondition(
            !PlaybackKeyboardRouting.isEditableTextSurface(field),
            "只读输入框不得当作可编辑文字面"
        )
        field.isEditable = true
        precondition(PlaybackKeyboardRouting.isEditableTextSurface(field))
    }

    private static func assertWindowFocusControllerClearsInitialResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let field = NSTextField(string: "hello world")
        field.isEditable = true
        window.contentView = field
        window.makeFirstResponder(field)

        let controller = PlaybackWindowFocusController()
        controller.attach(to: window)
        precondition(
            !controller.allowTextFocus,
            "窗口挂上时不得把输入框当作用户正在编辑"
        )
        if window.firstResponder != nil {
            precondition(
                !PlaybackKeyboardRouting.isEditingText(in: window),
                "窗口创建后第一响应者不得停在链接输入框"
            )
        }

        controller.detach()
        window.close()
    }

    private static func assertEscapeResignCarriesReason() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        var reasons: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .seeseeTextFocusShouldResign,
            object: window,
            queue: nil
        ) { notification in
            if let raw = notification.userInfo?[TextFocusResignReason.userInfoKey] as? String {
                reasons.append(raw)
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            window.close()
        }

        PlaybackWindowFocusController.resign(in: window, reason: .escape)
        precondition(
            reasons.last == TextFocusResignReason.escape.rawValue,
            "Esc 失焦必须带上 escape 原因，标题编辑才能取消而不是保存"
        )

        PlaybackWindowFocusController.resign(in: window, reason: .other)
        precondition(reasons.last == TextFocusResignReason.other.rawValue)

        let controller = PlaybackWindowFocusController()
        controller.attach(to: window)
        reasons.removeAll()
        controller.resignTextFocus(reason: .escape)
        precondition(reasons.last == TextFocusResignReason.escape.rawValue)
        controller.detach()
    }

    private static func assertEscapeThenClickOtherFieldCommitsTitle() {
        precondition(
            PlaybackWindowFocusController.mouseDownAction(
                hitsEditableText: true,
                isEditingText: true,
                hitsCurrentEditor: false
            ) == .commitPreviousAndAllowNewTextFocus,
            "标题编辑中点到另一个输入框，必须提交上一个字段"
        )
        precondition(
            PlaybackWindowFocusController.mouseDownAction(
                hitsEditableText: true,
                isEditingText: true,
                hitsCurrentEditor: true
            ) == .allowNewTextFocus,
            "点在当前编辑器内不得当成点走"
        )
        precondition(
            PlaybackWindowFocusController.mouseDownAction(
                hitsEditableText: true,
                isEditingText: false,
                hitsCurrentEditor: false
            ) == .allowNewTextFocus
        )
        precondition(
            PlaybackWindowFocusController.mouseDownAction(
                hitsEditableText: false,
                isEditingText: true,
                hitsCurrentEditor: false
            ) == .resignCurrent
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        var reasons: [TextFocusResignReason] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .seeseeTextFocusShouldResign,
            object: window,
            queue: nil
        ) { notification in
            reasons.append(TextFocusResignReason.from(notification))
        }
        let titleField = NSTextField(string: "草稿")
        titleField.isEditable = true
        window.contentView = titleField
        let controller = PlaybackWindowFocusController()
        controller.attach(to: window)
        defer {
            NotificationCenter.default.removeObserver(observer)
            controller.detach()
            window.close()
        }

        window.makeFirstResponder(titleField)
        controller.setSwiftUITextFieldFocused(true)
        PlaybackWindowFocusController.resign(in: window, reason: .escape)
        precondition(reasons.last == .escape)

        window.makeFirstResponder(titleField)
        controller.setSwiftUITextFieldFocused(true)
        reasons.removeAll()
        controller.performMouseDown(
            hitsEditableText: true,
            isEditingText: true,
            hitsCurrentEditor: false
        )
        precondition(
            reasons == [.other],
            "Esc 之后点另一个输入框必须再发 other，不得沿用 escape。实际：\(reasons)"
        )
        let clickAwayReason = TextFocusResignReason.from(
            Notification(
                name: .seeseeTextFocusShouldResign,
                object: window,
                userInfo: [TextFocusResignReason.userInfoKey: reasons[0].rawValue]
            )
        )
        precondition(clickAwayReason == .other, "标题点走必须读本次通知，不得读到上一轮 Esc")
    }

    private static func assertIdlePlaybackShortcuts() {
        precondition(
            route(keyCode: 49, hasActivePlayer: true) == .togglePlayback,
            "空闲时空格必须切换播放"
        )
        precondition(
            route(character: "f", keyCode: 3, hasActivePlayer: true) == .toggleFullscreen,
            "空闲时 F 必须切换全屏"
        )
        precondition(
            route(character: "F", keyCode: 3, hasActivePlayer: true) == .toggleFullscreen,
            "大写 F 必须与小写同样切换全屏"
        )
        precondition(
            route(character: "a", keyCode: 0, hasActivePlayer: true) == .passThrough,
            "看时问答已删除，a 必须原样放行"
        )
        precondition(
            route(character: "A", keyCode: 0, hasActivePlayer: true) == .passThrough,
            "看时问答已删除，大写 A 必须原样放行"
        )
        precondition(
            route(keyCode: 53, hasActivePlayer: true) == .exitFullscreen,
            "空闲时 Esc 必须退出全屏"
        )
        precondition(
            route(keyCode: 123, hasActivePlayer: true) == .skip(-10),
            "空闲时左方向键必须快退 10 秒"
        )
        precondition(
            route(keyCode: 124, hasActivePlayer: true) == .skip(10),
            "空闲时右方向键必须快进 10 秒"
        )
        precondition(
            route(keyCode: 126, hasActivePlayer: true) == .adjustRate(0.1),
            "空闲时上方向键必须加快播放速度"
        )
        precondition(
            route(keyCode: 125, hasActivePlayer: true) == .adjustRate(-0.1),
            "空闲时下方向键必须减慢播放速度"
        )
    }

    private static func assertEditingSpaceIsPassedThrough() {
        precondition(
            route(isEditingText: true, character: " ", keyCode: 49, hasActivePlayer: true)
                == .insertLiteralSpace,
            "编辑态无修饰空格必须写入普通空格，避免被播放按钮吃掉"
        )
        precondition(
            route(isEditingText: true, character: " ", keyCode: 49, hasActivePlayer: false)
                == .insertLiteralSpace,
            "无播放器时，编辑态无修饰空格同样写入普通空格"
        )
        for character in ["a", "h", "1", ".", "/", "w"] {
            precondition(
                route(isEditingText: true, character: character, keyCode: 0, hasActivePlayer: true)
                    == .passThrough,
                "编辑态可打印字符必须原样交给输入框"
            )
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let field = NSTextField(string: "")
        field.isEditable = true
        window.contentView = field
        let controller = PlaybackWindowFocusController()
        controller.attach(to: window)
        window.makeFirstResponder(field)

        precondition(
            !controller.allowTextFocus,
            "HID 聚焦不经过点击监听时，allowTextFocus 仍为假"
        )
        precondition(
            PlaybackKeyboardRouting.isEditingText(in: window),
            "输入框持有第一响应者时必须判定为编辑态"
        )
        precondition(
            PlaybackKeyboardRouting.action(
                in: window,
                keyCode: 49,
                character: " ",
                modifiers: [],
                hasActivePlayer: true
            ) == .insertLiteralSpace,
            "编辑态无修饰空格必须写入普通空格：按键决策只看第一响应者"
        )
        precondition(
            PlaybackKeyboardRouting.isEditingText(in: window),
            "判定编辑态空格时不得先清掉输入框焦点"
        )

        controller.detach()
        window.close()
    }

    private static func assertModifierSpaceIsPassedThrough() {
        precondition(
            route(isEditingText: true, keyCode: 49, modifiers: .option, hasActivePlayer: true)
                == .passThrough,
            "编辑态 Option-Space 必须原样放行，不得改写成普通空格"
        )
        precondition(
            route(isEditingText: true, keyCode: 49, modifiers: .shift, hasActivePlayer: true)
                == .passThrough,
            "编辑态 Shift-Space 必须原样放行"
        )
        precondition(
            route(isEditingText: true, keyCode: 49, modifiers: .command, hasActivePlayer: true)
                == .passThrough,
            "编辑态 Command-Space 必须原样放行"
        )
        precondition(
            route(isEditingText: true, keyCode: 49, modifiers: .control, hasActivePlayer: true)
                == .passThrough,
            "编辑态 Control-Space 必须原样放行"
        )
        precondition(
            route(
                isEditingText: true,
                keyCode: 49,
                modifiers: [.option, .shift],
                hasActivePlayer: true
            ) == .passThrough,
            "编辑态带多个修饰键的空格必须原样放行"
        )
        precondition(
            route(isEditingText: true, keyCode: 49, modifiers: [], hasActivePlayer: true)
                == .insertLiteralSpace,
            "只有无修饰键的普通空格才写入 U+0020"
        )
    }

    private static func assertSpacePassesWhenReceivingTextInput() {
        precondition(
            PlaybackKeyboardRouting.isTextInputClassName("SwiftUI.TextFieldHost"),
            "SwiftUI 输入框类名必须识别为文字输入"
        )
        precondition(!PlaybackKeyboardRouting.isTextInputClassName("NSButton"))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentLayoutRect)
        let controller = PlaybackWindowFocusController()
        controller.attach(to: window)
        precondition(
            !PlaybackKeyboardRouting.isEditingText(in: window),
            "未点击输入框时不得当作正在编辑"
        )
        precondition(
            PlaybackKeyboardRouting.action(
                in: window,
                keyCode: 49,
                character: " ",
                modifiers: [],
                hasActivePlayer: true
            ) == .togglePlayback,
            "未在输入时，空格才是播放快捷键"
        )

        precondition(
            PlaybackKeyboardRouting.action(
                in: window,
                keyCode: 49,
                character: " ",
                modifiers: [],
                hasActivePlayer: true
            ) == .togglePlayback,
            "第一响应者不是输入框时，空格必须仍是播放快捷键"
        )
        precondition(
            PlaybackKeyboardRouting.action(
                in: window,
                keyCode: 4,
                character: "h",
                modifiers: [],
                hasActivePlayer: true
            ) == .passThrough
        )

        controller.setSwiftUITextFieldFocused(false)
        controller.resignTextFocus()
        precondition(
            PlaybackKeyboardRouting.action(
                in: window,
                keyCode: 49,
                character: " ",
                modifiers: [],
                hasActivePlayer: true
            ) == .togglePlayback,
            "失焦后空格必须恢复为播放快捷键"
        )

        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        editor.isEditable = true
        editor.string = "hi"
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        window.contentView = editor
        window.makeFirstResponder(editor)
        precondition(
            PlaybackKeyboardRouting.insertPlainText(" ", in: window),
            "编辑态空格必须能写入字段编辑器"
        )
        precondition(
            editor.string == "hi ",
            "写入后字段必须含空格"
        )
        precondition(
            PlaybackKeyboardRouting.insertPlainText("x", in: window)
        )
        precondition(editor.string == "hi x")

        controller.detach()
        window.close()
    }

    private static func assertEditingPassesText() {
        precondition(
            route(isEditingText: true, keyCode: 49, hasActivePlayer: true) == .insertLiteralSpace,
            "编辑态无修饰空格必须写入普通空格"
        )
        precondition(
            route(isEditingText: true, character: "f", keyCode: 3, hasActivePlayer: true) == .passThrough,
            "编辑态 F 必须留给文字"
        )
        precondition(
            route(isEditingText: true, keyCode: 123, hasActivePlayer: true) == .passThrough,
            "编辑态左方向键必须移动光标"
        )
        precondition(
            route(isEditingText: true, keyCode: 124, hasActivePlayer: true) == .passThrough,
            "编辑态右方向键必须移动光标"
        )
        precondition(
            route(isEditingText: true, keyCode: 125, hasActivePlayer: true) == .passThrough,
            "编辑态下方向键必须留给文字"
        )
        precondition(
            route(isEditingText: true, keyCode: 126, hasActivePlayer: true) == .passThrough,
            "编辑态上方向键必须留给文字"
        )
        precondition(
            route(
                isEditingText: true,
                character: "v",
                keyCode: 9,
                modifiers: .command,
                hasActivePlayer: true
            ) == .passThrough,
            "编辑态 Command-V 必须走系统粘贴"
        )
        precondition(
            route(isEditingText: true, character: "h", keyCode: 4, hasActivePlayer: true) == .passThrough,
            "编辑态普通字母必须留给文字"
        )
        precondition(
            route(isEditingText: true, keyCode: 53, hasActivePlayer: true) == .resignTextFocus,
            "编辑态 Esc 必须退出输入框，不得再交给全屏"
        )
        precondition(
            route(
                isEditingText: true,
                keyCode: 53,
                modifiers: .command,
                hasActivePlayer: true
            ) == .passThrough,
            "编辑态带修饰键的 Esc 必须放行"
        )
    }

    private static func assertLeftoverTextDoesNotBlockShortcuts() {
        precondition(
            route(isEditingText: false, keyCode: 49, hasActivePlayer: true) == .togglePlayback,
            "输入框有未提交文字但已失焦时，空格必须仍切换播放"
        )
        precondition(
            route(isEditingText: false, character: "f", keyCode: 3, hasActivePlayer: true)
                == .toggleFullscreen,
            "输入框有未提交文字但已失焦时，F 必须仍切换全屏"
        )
        precondition(
            route(isEditingText: false, keyCode: 53, hasActivePlayer: true) == .exitFullscreen,
            "输入框有未提交文字但已失焦时，Esc 必须仍退出全屏"
        )
        precondition(
            route(isEditingText: false, keyCode: 123, hasActivePlayer: true) == .skip(-10),
            "输入框有未提交文字但已失焦时，方向键必须仍快退"
        )
    }

    private static func assertModifierCombinations() {
        precondition(
            route(keyCode: 49, modifiers: .shift, hasActivePlayer: true) == .passThrough,
            "Shift-空格不得切换播放"
        )
        precondition(
            route(character: "f", keyCode: 3, modifiers: .command, hasActivePlayer: true)
                == .passThrough,
            "Command-F 不得切换全屏"
        )
        precondition(
            route(keyCode: 49, modifiers: .option, hasActivePlayer: true) == .passThrough,
            "Option-空格不得切换播放"
        )
        precondition(
            route(keyCode: 49, modifiers: .control, hasActivePlayer: true) == .passThrough,
            "Control-空格不得切换播放"
        )
        precondition(
            route(character: "v", keyCode: 9, modifiers: .command, hasActivePlayer: true) == .pasteURL,
            "空闲时 Command-V 必须按链接粘贴"
        )
        precondition(
            route(character: "V", keyCode: 9, modifiers: .command, hasActivePlayer: false) == .pasteURL,
            "无播放器时 Command-V 仍必须按链接粘贴"
        )
        precondition(
            route(
                character: "v",
                keyCode: 9,
                modifiers: [.command, .shift],
                hasActivePlayer: true
            ) == .passThrough,
            "Command-Shift-V 不得按链接粘贴"
        )
        precondition(
            route(keyCode: 123, modifiers: .shift, hasActivePlayer: true) == .passThrough,
            "Shift-左方向键不得快退"
        )
    }

    private static func assertMissingPlayer() {
        precondition(
            route(keyCode: 49, hasActivePlayer: false) == .passThrough,
            "无播放器时空格必须放行"
        )
        precondition(
            route(character: "f", keyCode: 3, hasActivePlayer: false) == .passThrough,
            "无播放器时 F 必须放行"
        )
        precondition(
            route(keyCode: 123, hasActivePlayer: false) == .passThrough,
            "无播放器时左方向键必须放行"
        )
        precondition(
            route(keyCode: 124, hasActivePlayer: false) == .passThrough,
            "无播放器时右方向键必须放行"
        )
        precondition(
            route(keyCode: 125, hasActivePlayer: false) == .passThrough,
            "无播放器时下方向键必须放行"
        )
        precondition(
            route(keyCode: 126, hasActivePlayer: false) == .passThrough,
            "无播放器时上方向键必须放行"
        )
        precondition(
            route(keyCode: 53, hasActivePlayer: false) == .exitFullscreen,
            "无播放器时 Esc 仍交给退出全屏，由调用方决定是否消费"
        )
    }

    private static func route(
        isEditingText: Bool = false,
        character: String? = nil,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        hasActivePlayer: Bool
    ) -> PlaybackKeyboardAction {
        PlaybackKeyboardRouting.action(
            isEditingText: isEditingText,
            keyCode: keyCode,
            character: character,
            modifiers: modifiers,
            hasActivePlayer: hasActivePlayer
        )
    }
}
