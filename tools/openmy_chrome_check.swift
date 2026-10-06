import AppKit
import Foundation

@main
struct OpenMyChromeCheck {
    static func main() {
        precondition(OpenMyChrome.canvasHex == 0x0D0D0D, "画布必须是 openmy #0D0D0D")
        precondition(OpenMyChrome.raiseHex == 0x1E1E1E, "悬浮层必须是 openmy #1E1E1E")
        precondition(OpenMyChrome.hairHex == 0x222222, "细线必须是 openmy #222222")
        precondition(OpenMyChrome.fieldBorderHex == 0x2A2A2A)
        precondition(OpenMyChrome.inkHex == 0xECECEC, "正文必须是 openmy #ECECEC")
        precondition(OpenMyChrome.mutedHex == 0x9B9B9B)
        precondition(OpenMyChrome.faintHex == 0x666666)
        precondition(OpenMyChrome.successHex == 0x41B98C)
        precondition(OpenMyChrome.warningHex == 0xD9A44C)
        precondition(OpenMyChrome.recHex == 0xE0607E)
        precondition(OpenMyChrome.radiusSm == 8)
        precondition(OpenMyChrome.radiusMd == 10)
        precondition(OpenMyChrome.radiusLg == 12)
        precondition(OpenMyChrome.radiusXl == 16)
        precondition(OpenMyChrome.paneHeaderHeight == 56, "各栏顶栏必须是 56 点，分隔线才对齐")

        precondition(OpenMyChrome.rowSurfaceHex(selected: false, pressed: false, hovering: false) == nil)
        precondition(OpenMyChrome.rowSurfaceHex(selected: false, pressed: false, hovering: true) == OpenMyChrome.rowHoverHex)
        precondition(OpenMyChrome.rowSurfaceHex(selected: true, pressed: false, hovering: false) == OpenMyChrome.rowSelectedHex)
        precondition(OpenMyChrome.rowSurfaceHex(selected: true, pressed: true, hovering: true) == OpenMyChrome.rowPressedHex)
        precondition(
            OpenMyChrome.rowSelectedHex > OpenMyChrome.raiseHex,
            "选中必须比旧 raise 更亮，否则 #1E1E1E 叠在 #0D0D0D 上看不出点中"
        )
        precondition(OpenMyChrome.rowPressedHex > OpenMyChrome.rowSelectedHex)

        // 浅色取 openmy globals.css `:root`。
        precondition(OpenMyChrome.lightCanvasHex == 0xF9F9FA, "浅色画布必须是 openmy --background #F9F9FA")
        precondition(OpenMyChrome.lightInkHex == 0x1A1A1F, "浅色正文必须是 openmy --foreground #1A1A1F")
        precondition(OpenMyChrome.lightHairHex == 0xECECEF)
        precondition(OpenMyChrome.lightMutedHex == 0x65656E)
        precondition(OpenMyChrome.lightFaintHex == 0x909099)
        precondition(OpenMyChrome.lightSuccessHex == 0x2FA878)
        precondition(OpenMyChrome.lightWarningHex == 0xC08A2D)
        precondition(OpenMyChrome.lightRecHex == 0xCC3F50)
        precondition(
            contrast(OpenMyChrome.lightMutedHex, OpenMyChrome.lightRowSelectedHex) >= 4.5,
            "浅色次要文字在选中行上必须达到 WCAG AA 4.5:1"
        )
        precondition(
            contrast(OpenMyChrome.lightRecHex, OpenMyChrome.lightCanvasHex) >= 4.5,
            "浅色警示红在画布上必须达到 WCAG AA 4.5:1"
        )
        precondition(
            OpenMyChrome.lightRowSelectedHex < OpenMyChrome.lightRaiseHex,
            "浅色下选中必须比 raise 更深，否则叠在画布上看不出点中"
        )
        precondition(OpenMyChrome.lightRowPressedHex < OpenMyChrome.lightRowSelectedHex)
        precondition(OpenMyChrome.lightRowHoverHex < OpenMyChrome.lightCanvasHex)
        precondition(OpenMyChrome.lightRowSelectedStrokeHex < OpenMyChrome.lightRowPressedHex)

        // 同一个颜色在两种外观下取不同的值：深色外观取深色值，浅色外观取浅色值。
        let colors: [(NSColor, UInt32, UInt32)] = [
            (OpenMyChrome.nsCanvas, OpenMyChrome.canvasHex, OpenMyChrome.lightCanvasHex),
            (OpenMyChrome.nsInk, OpenMyChrome.inkHex, OpenMyChrome.lightInkHex),
            (OpenMyChrome.nsMuted, OpenMyChrome.mutedHex, OpenMyChrome.lightMutedHex),
            (OpenMyChrome.nsRaise, OpenMyChrome.raiseHex, OpenMyChrome.lightRaiseHex),
            (OpenMyChrome.nsRowHover, OpenMyChrome.rowHoverHex, OpenMyChrome.lightRowHoverHex),
        ]
        for (color, dark, light) in colors {
            precondition(resolvedHex(color, in: .darkAqua) == dark, "深色外观取错了色值")
            precondition(resolvedHex(color, in: .aqua) == light, "浅色外观取错了色值")
        }

        // 外观设置默认跟随系统；跟随系统时不指定外观，交还给系统。
        let defaults = UserDefaults(suiteName: "openmy-chrome-check-\(UUID().uuidString)")!
        precondition(AppearanceSetting.stored(in: defaults) == .system)
        precondition(AppearanceSetting.system.appearanceName == nil)
        precondition(AppearanceSetting.light.appearanceName == .aqua)
        precondition(AppearanceSetting.dark.appearanceName == .darkAqua)
        defaults.set("light", forKey: AppearanceSetting.defaultsKey)
        precondition(AppearanceSetting.stored(in: defaults) == .light)
        defaults.set("bogus", forKey: AppearanceSetting.defaultsKey)
        precondition(AppearanceSetting.stored(in: defaults) == .system, "存了认不得的值时退回跟随系统")
        precondition(AppearanceSetting.allCases.map(\.title) == ["跟随系统", "浅色", "深色"])

        print("openmy_chrome_check=passed")
    }

    /// WCAG 2 对比度：两色相对亮度 (亮 + 0.05) / (暗 + 0.05)。
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [16, 8, 0].map { Double((hex >> UInt32($0)) & 0xFF) / 255 }
                .map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    static func resolvedHex(_ color: NSColor, in name: NSAppearance.Name) -> UInt32 {
        var hex: UInt32 = 0
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let srgb = color.usingColorSpace(.sRGB)!
            let r = UInt32((srgb.redComponent * 255).rounded())
            let g = UInt32((srgb.greenComponent * 255).rounded())
            let b = UInt32((srgb.blueComponent * 255).rounded())
            hex = (r << 16) | (g << 8) | b
        }
        return hex
    }
}
