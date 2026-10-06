import AppKit
import SwiftUI

/// 右栏句块的排版宽度必须等于视图宽度、排出来的字不能超出视图高度。
/// SwiftUI 布局时会拿试探宽度问尺寸；量尺寸时改了文本视图的排版宽度，句子就停在试探宽度上挤成窄列、
/// 末尾被裁掉。这里离屏摆出和右栏相同的句块列表，逐个核对每个文本视图。
@main
struct DigestRowWidthCheck {
    static let cues = [
        "All right, so here we are, in front of the elephants the cool thing about these guys is that they have really...",
        "really really long trunks and that's cool (baaaaaaaaaaahhh!!) and that's pretty much all there is to say",
        "I've always wanted about four features from a text editor from a writing environment something like that.",
        "Hello everyone.\n大家好。"
    ]

    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var failures: [String] = []
        for width in [CGFloat(300), 340, 420] {
            for current in [0, 1] {
                failures += check(width: width, current: current)
            }
        }
        guard failures.isEmpty else {
            failures.forEach { print("失败：\($0)") }
            print("digest_row_width_check=failed (\(failures.count))")
            exit(1)
        }
        print("digest_row_width_check=passed")
    }

    @MainActor
    private static func check(width: CGFloat, current: Int) -> [String] {
        let hosting = NSHostingView(rootView: RowList(cues: cues, current: current))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            hosting.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        defer { window.orderOut(nil) }

        let views = textViews(in: hosting)
        var failures: [String] = []
        if views.count != cues.count {
            failures.append("宽 \(width)：应摆出 \(cues.count) 个句块，实际 \(views.count)")
        }
        for view in views {
            guard let container = view.textContainer, let manager = view.layoutManager else { continue }
            manager.ensureLayout(for: container)
            let used = ceil(manager.usedRect(for: container).height)
            let label = "宽 \(width) 当前第 \(current) 句「\(view.string.prefix(24))…」"
            if abs(container.size.width - view.bounds.width) > 1 {
                failures.append("\(label)排版宽 \(container.size.width)，视图宽 \(view.bounds.width)")
            }
            if used > view.bounds.height + 1 {
                failures.append("\(label)字要 \(used) 高，视图只有 \(view.bounds.height)，末尾被裁掉")
            }
        }
        return failures
    }

    private static func textViews(in view: NSView) -> [FittingTextView] {
        var found: [FittingTextView] = []
        for sub in view.subviews {
            if let text = sub as? FittingTextView { found.append(text) }
            found += textViews(in: sub)
        }
        return found.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }
}

/// 和右栏同样的摆法：滚动区里的懒加载列表，每行时间码加句块，左右留白。
private struct RowList: View {
    let cues: [String]
    let current: Int

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DigestCueDisplay.blockSpacing) {
                ForEach(Array(cues.enumerated()), id: \.offset) { index, text in
                    DigestCueRow(
                        timeLabel: "0:0\(index)",
                        cueText: text,
                        timeColumnWidth: 36,
                        isCurrent: index == current
                    )
                    .padding(.leading, 10)
                    .padding(.trailing, 14)
                    .padding(.vertical, DigestCueDisplay.rowVerticalPadding)
                }
            }
        }
    }
}
