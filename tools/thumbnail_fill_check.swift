import AppKit
import SwiftUI

// 看板卡片缩略图的检查：封面比 16:9 宽时，缩略图不能把卡片撑宽。
// 旧写法（图片直接 fill 再 frame(maxWidth: .infinity)）在 229×129 的框里报出 387 宽，卡片被撑开、左边被切。
// 在没有 ThumbnailFill 的代码上编译即失败。

@main
struct ThumbnailFillCheck {
    static func main() {
        _ = NSApplication.shared
        var failures: [String] = []
        let proposal = CGSize(width: 229, height: 129)

        for (name, size) in [("16:9", NSSize(width: 1280, height: 720)),
                             ("3:1", NSSize(width: 1500, height: 500)),
                             ("9:16", NSSize(width: 720, height: 1280)),
                             ("1:1", NSSize(width: 800, height: 800))] {
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.systemRed.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.unlockFocus()

            // 和 BoardCardThumbnail 一样的外层：宽度跟着列走，高度固定。
            let thumbnail = ThumbnailFill(image: image)
                .frame(maxWidth: .infinity)
                .frame(height: proposal.height)
            let fitted = NSHostingController(rootView: thumbnail).sizeThatFits(in: proposal)
            if abs(fitted.width - proposal.width) > 0.5 || abs(fitted.height - proposal.height) > 0.5 {
                failures.append("\(name) 封面把缩略图撑成了 \(fitted.width)×\(fitted.height)，应为 \(proposal.width)×\(proposal.height)")
            }
        }

        if failures.isEmpty {
            print("thumbnail_fill_check=passed")
        } else {
            failures.forEach { print("失败：\($0)") }
            exit(1)
        }
    }
}
