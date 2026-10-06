import AppKit
import SwiftUI

/// openmy 配色（globals.css）：深色取 `.dark` 终案（2026-07-14），浅色取 `:root`（2026-07-12）。
/// 深色：整窗一个黑 #0D0D0D，悬浮层 #1E1E1E，细线 #222222，文字 #ECECEC 起步。
/// 浅色：底 #F9F9FA，raise #ECECEE，细线 #ECECEF，文字 #1A1A1F。
/// 两套都是黑白灰为体、层级只靠明度台阶；每个颜色按所在视图的外观取深色或浅色值。
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
    /// 选中行描边。发丝线与选中底色只差一档看不出来，选中态需要亮一档的边。
    static let rowSelectedStrokeHex: UInt32 = 0x3A3A3A

    /// 浅色值。名字与深色一一对应，来源变量写在每行后面。
    static let lightCanvasHex: UInt32 = 0xF9F9FA // --background
    static let lightRaiseHex: UInt32 = 0xECECEE // --accent（css 注明即 raise）
    static let lightHairHex: UInt32 = 0xECECEF // --border
    static let lightFieldBorderHex: UInt32 = 0xECECEF // --field-border（浅色与 hair 同值）
    static let lightInkHex: UInt32 = 0x1A1A1F // --foreground / --text-primary
    // muted、faint、rec 比 openmy 原值（#6F6F78、#9C9CA5、#D84A5B）各深一点：
    // muted 在选中行上、rec 在画布上要到 WCAG AA 4.5:1，faint 在画布上到 3:1。
    static let lightMutedHex: UInt32 = 0x65656E // --text-secondary / --muted-foreground
    static let lightFaintHex: UInt32 = 0x909099 // --text-tertiary
    static let lightSuccessHex: UInt32 = 0x2FA878 // --success
    static let lightWarningHex: UInt32 = 0xC08A2D // --warning
    static let lightRecHex: UInt32 = 0xCC3F50 // --rec
    static let lightRowHoverHex: UInt32 = 0xF2F2F3 // --surface-secondary：介于画布和 raise 之间
    static let lightRowSelectedHex: UInt32 = 0xE3E3E8 // --accent-hover
    static let lightRowPressedHex: UInt32 = 0xDCDCE0 // css 无对应，比选中再深一档
    static let lightRowSelectedStrokeHex: UInt32 = 0xC9C9CF // --brand-5

    static let nsCanvas = NSColor(dark: canvasHex, light: lightCanvasHex)
    static let nsRaise = NSColor(dark: raiseHex, light: lightRaiseHex)
    static let nsHair = NSColor(dark: hairHex, light: lightHairHex)
    static let nsFieldBorder = NSColor(dark: fieldBorderHex, light: lightFieldBorderHex)
    static let nsInk = NSColor(dark: inkHex, light: lightInkHex)
    static let nsMuted = NSColor(dark: mutedHex, light: lightMutedHex)
    static let nsFaint = NSColor(dark: faintHex, light: lightFaintHex)
    static let nsSuccess = NSColor(dark: successHex, light: lightSuccessHex)
    static let nsWarning = NSColor(dark: warningHex, light: lightWarningHex)
    static let nsRec = NSColor(dark: recHex, light: lightRecHex)
    static let nsRowHover = NSColor(dark: rowHoverHex, light: lightRowHoverHex)
    static let nsRowSelected = NSColor(dark: rowSelectedHex, light: lightRowSelectedHex)
    static let nsRowPressed = NSColor(dark: rowPressedHex, light: lightRowPressedHex)
    static let nsRowSelectedStroke = NSColor(dark: rowSelectedStrokeHex, light: lightRowSelectedStrokeHex)

    static let canvas = Color(nsColor: nsCanvas)
    static let raise = Color(nsColor: nsRaise)
    static let hair = Color(nsColor: nsHair)
    static let fieldBorder = Color(nsColor: nsFieldBorder)
    static let ink = Color(nsColor: nsInk)
    static let muted = Color(nsColor: nsMuted)
    static let faint = Color(nsColor: nsFaint)
    static let success = Color(nsColor: nsSuccess)
    static let warning = Color(nsColor: nsWarning)
    static let rec = Color(nsColor: nsRec)

    static let radiusSm: CGFloat = 8
    static let radiusMd: CGFloat = 10
    static let radiusLg: CGFloat = 12
    static let radiusXl: CGFloat = 16
    /// 主窗口各栏顶栏高度。左右分隔线落在这一高度的下沿。
    static let paneHeaderHeight: CGFloat = 56

    static let rowHover = Color(nsColor: nsRowHover)
    static let rowSelected = Color(nsColor: nsRowSelected)
    static let rowPressed = Color(nsColor: nsRowPressed)
    static let rowSelectedStroke = Color(nsColor: nsRowSelectedStroke)

    /// 按下 > 选中 > 悬停 > 无底。深色下选中必须比 raise 更亮，浅色下必须比 raise 更深，
    /// 否则叠在画布上看不出点中。
    static func rowSurfaceHex(selected: Bool, pressed: Bool, hovering: Bool) -> UInt32? {
        if pressed { return rowPressedHex }
        if selected { return rowSelectedHex }
        if hovering { return rowHoverHex }
        return nil
    }

    static func rowFill(selected: Bool, pressed: Bool, hovering: Bool) -> Color? {
        if pressed { return rowPressed }
        if selected { return rowSelected }
        if hovering { return rowHover }
        return nil
    }

    /// 按设置里的「外观」改整个应用的外观；跟随系统时交还给系统。改完立刻生效。
    static func applyAppearance(_ setting: AppearanceSetting = .stored()) {
        NSApp.appearance = setting.appearanceName.flatMap(NSAppearance.init(named:))
        refreshChromedWindows()
    }

    private static let chromedWindows = NSHashTable<NSWindow>.weakObjects()
    private static var appearanceObservation: NSKeyValueObservation?

    static func applyWindowChrome(_ window: NSWindow) {
        window.backgroundColor = nsCanvas
        window.contentView?.wantsLayer = true
        chromedWindows.add(window)
        refreshLayerBackground(of: window)
        // 系统外观切换时 NSApp.effectiveAppearance 会变；图层底色是一次性取值，要跟着重取。
        if appearanceObservation == nil {
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
                DispatchQueue.main.async { refreshChromedWindows() }
            }
        }
    }

    private static func refreshChromedWindows() {
        for window in chromedWindows.allObjects {
            refreshLayerBackground(of: window)
        }
    }

    private static func refreshLayerBackground(of window: NSWindow) {
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.contentView?.layer?.backgroundColor = nsCanvas.cgColor
        }
    }
}

/// 设置里的「外观」：跟随系统、浅色、深色。存在偏好设置里，默认跟随系统。
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "appearance"
    static let label = "外观"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// nil 表示不指定，应用跟随系统外观。
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppearanceSetting {
        defaults.string(forKey: defaultsKey).flatMap(AppearanceSetting.init(rawValue:)) ?? .system
    }
}

extension NSColor {
    /// 深浅两值的动态色：按绘制时的外观取值，系统或应用外观一变，下次绘制就换。
    convenience init(dark: UInt32, light: UInt32) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
