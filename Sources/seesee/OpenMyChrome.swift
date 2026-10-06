import AppKit
import SwiftUI

/// openmy 深色终案（globals.css `.dark`，2026-07-14）：
/// 整窗一个黑 #0D0D0D，悬浮层 #1E1E1E，细线 #222222，
/// 零饱和度，文字 #ECECEC 起步，层级只靠明度台阶。
enum OpenMyChrome {
    static let canvasHex: UInt32 = 0x0D0D0D
    static let raiseHex: UInt32 = 0x1E1E1E
    static let hairHex: UInt32 = 0x222222
    static let fieldBorderHex: UInt32 = 0x2A2A2A
    static let inkHex: UInt32 = 0xECECEC
    static let mutedHex: UInt32 = 0x9B9B9B
    static let faintHex: UInt32 = 0x666666
    static let successHex: UInt32 = 0x41B98C
    static let warningHex: UInt32 = 0xD9A44C
    static let recHex: UInt32 = 0xE0607E
    static let rowHoverHex: UInt32 = 0x181818
    static let rowSelectedHex: UInt32 = 0x2A2A2A
    static let rowPressedHex: UInt32 = 0x333333

    static let canvas = Color(hex: canvasHex)
    static let raise = Color(hex: raiseHex)
    static let hair = Color(hex: hairHex)
    static let fieldBorder = Color(hex: fieldBorderHex)
    static let ink = Color(hex: inkHex)
    static let muted = Color(hex: mutedHex)
    static let faint = Color(hex: faintHex)
    static let success = Color(hex: successHex)
    static let warning = Color(hex: warningHex)
    static let rec = Color(hex: recHex)

    static let nsCanvas = NSColor(srgbRed: 13 / 255, green: 13 / 255, blue: 13 / 255, alpha: 1)
    static let nsRaise = NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
    static let nsHair = NSColor(srgbRed: 34 / 255, green: 34 / 255, blue: 34 / 255, alpha: 1)
    static let nsInk = NSColor(srgbRed: 236 / 255, green: 236 / 255, blue: 236 / 255, alpha: 1)
    static let nsMuted = NSColor(srgbRed: 155 / 255, green: 155 / 255, blue: 155 / 255, alpha: 1)
    static let nsFaint = NSColor(srgbRed: 102 / 255, green: 102 / 255, blue: 102 / 255, alpha: 1)
    static let nsFieldBorder = NSColor(srgbRed: 42 / 255, green: 42 / 255, blue: 42 / 255, alpha: 1)
    static let nsRowSelectedStroke = NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 58 / 255, alpha: 1)
    static let nsRowHover = NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 24 / 255, alpha: 1)

    static let radiusSm: CGFloat = 8
    static let radiusMd: CGFloat = 10
    static let radiusLg: CGFloat = 12
    static let radiusXl: CGFloat = 16
    /// 主窗口各栏顶栏高度。左右分隔线落在这一高度的下沿。
    static let paneHeaderHeight: CGFloat = 56

    static let rowHover = Color(hex: rowHoverHex)
    static let rowSelected = Color(hex: rowSelectedHex)
    static let rowPressed = Color(hex: rowPressedHex)

    /// 选中行描边。发丝线与选中底色只差一档看不出来，选中态需要亮一档的边。
    static let rowSelectedStrokeHex: UInt32 = 0x3A3A3A
    static let rowSelectedStroke = Color(hex: rowSelectedStrokeHex)

    /// 按下 > 选中 > 悬停 > 无底。选中必须比 raise 更亮，否则叠在画布上看不出点中。
    static func rowSurfaceHex(selected: Bool, pressed: Bool, hovering: Bool) -> UInt32? {
        if pressed { return rowPressedHex }
        if selected { return rowSelectedHex }
        if hovering { return rowHoverHex }
        return nil
    }

    static func rowFill(selected: Bool, pressed: Bool, hovering: Bool) -> Color? {
        guard let hex = rowSurfaceHex(selected: selected, pressed: pressed, hovering: hovering) else {
            return nil
        }
        return Color(hex: hex)
    }

    static func applyAppearance() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    static func applyWindowChrome(_ window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = nsCanvas
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = nsCanvas.cgColor
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
