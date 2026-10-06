import AppKit
import SwiftUI

@main
struct MediaFolderSettingsProof {
    static let connectedPath = "/tmp/media-folder-settings-connected.png"
    static let disconnectedPath = "/tmp/media-folder-settings-disconnected.png"
    static let switchedPath = "/tmp/media-folder-settings-switched.png"

    @MainActor
    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        OpenMyChrome.applyAppearance()

        let media = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/seesee")

        let connected = DigestSettingsModel(mediaFolder: media)
        let connectedHeight = render(model: connected, path: connectedPath)
        precondition(connectedHeight <= 460, "正常设置页高度 \(connectedHeight) 超出预期")

        let disconnected = DigestSettingsModel(
            mediaFolder: URL(fileURLWithPath: "/Volumes/不存在的卷/seesee", isDirectory: true),
            isMediaFolderDisconnected: true
        )
        let disconnectedHeight = render(model: disconnected, path: disconnectedPath)
        precondition(disconnectedHeight <= 520, "未连接设置页高度 \(disconnectedHeight) 超出预期")

        let switched = DigestSettingsModel(
            mediaFolder: URL(fileURLWithPath: "/Volumes/外置硬盘/seesee", isDirectory: true)
        )
        switched.previousMediaFolder = media
        precondition(switched.previousMediaPathText == DigestSettingsCopy.displayPath(media))
        let switchedHeight = render(model: switched, path: switchedPath)
        precondition(switchedHeight > connectedHeight, "切换后应多出旧位置一行")
        precondition(switchedHeight <= 520, "切换后设置页高度 \(switchedHeight) 超出预期")
        print(
            "media_folder_settings_proof=passed connected=\(connectedPath) disconnected=\(disconnectedPath) switched=\(switchedPath)"
        )
    }

    @MainActor
    @discardableResult
    private static func render(model: DigestSettingsModel, path: String) -> CGFloat {
        let hosting = NSHostingView(rootView: DigestSettingsView(model: model))
        hosting.appearance = NSAppearance(named: .darkAqua)
        let fitting = hosting.fittingSize
        let width = DigestSettingsView.width
        let height = max(fitting.height, 200)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = OpenMyChrome.nsCanvas
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fatalError("media_folder_settings_proof: 无法建位图") }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("media_folder_settings_proof: 无法编码 \(path)")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fatalError("media_folder_settings_proof: 写 \(path) 失败 \(error)")
        }
        print(
            "media_folder_settings_proof size=\(Int(width))x\(Int(height)) disconnected=\(model.isMediaFolderDisconnected) path=\(model.mediaPathText) png=\(path)"
        )
        window.close()
        // 比较的是内容高度：AI 密钥区删掉后整页不到 200 点，按画布下限比较会看不出多出的一行。
        return fitting.height
    }
}
