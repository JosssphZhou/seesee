import Foundation
import Speech

/// 只查询真实系统语言资产，不下载、不删权重、不启动应用。
@main
struct AppleSpeechAssetsCheck {
    @MainActor static func main() async {
        if #available(macOS 26, *) {
            print("installedLocales=\(await SpeechTranscriber.installedLocales.map(\.identifier))")
            if let modules = try? await AppleSpeechAssets.modules() {
                for module in modules { print("resolved=\(module.selectedLocales.map(\.identifier)) status=\(await AssetInventory.status(forModules: [module]))") }
            }
        }
        let state = await AppleSpeechModelBackend().currentState()
        if #available(macOS 26, *) {
            let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
            if installed.contains("en_US") && installed.contains("zh_CN") {
                precondition(state == .available, "真实系统已安装中英文时，设置页必须显示可用")
            }
        }
        switch state {
        case .available: print("apple_speech_assets=available (中英文均已安装)")
        case .notInstalled: print("apple_speech_assets=notInstalled")
        case .downloading(let fraction): print("apple_speech_assets=downloading fraction=\(fraction)")
        case .failed: print("apple_speech_assets=failed")
        case .unsupportedSystem: print("apple_speech_assets=unsupportedSystem")
        }
    }
}
