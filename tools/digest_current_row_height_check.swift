import AppKit
import Foundation

/// 右栏正在播的句块译文行加粗，行高必须按加粗后的排版量，否则末尾一行被裁掉。
/// 两句都取自真实字幕：《Me at the zoo》单语合并后的句块，和一段 X 视频的英文句块。
@main
struct DigestCurrentRowHeightCheck {
    static let sentences = [
        "really really long trunks and that's cool (baaaaaaaaaaahhh!!) and that's pretty much all there is to say",
        "I've always wanted about four features from a text editor from a writing environment something like that. Something where I can write ideas down I can play with them I can play with different versions of words and headlines and paragraphs",
        "Hello everyone.\n大家好。"
    ]

    static func main() {
        var failures: [String] = []
        for text in sentences {
            for width in stride(from: CGFloat(200), through: 360, by: 5) {
                let rendered = usedHeight(
                    DigestCueDisplay.attributedString(
                        text: text,
                        query: "",
                        isCurrent: true,
                        originalColor: .white,
                        translationColor: .white
                    ),
                    width: width
                )
                let measured = DigestCueDisplay.blockHeight(for: text, width: width, isCurrent: true)
                if measured < rendered {
                    failures.append("宽 \(width) 量出 \(measured)，加粗实际要 \(rendered)：\(text.prefix(30))…")
                }
            }
        }
        guard failures.isEmpty else {
            failures.forEach { print("失败：\($0)") }
            print("digest_current_row_height_check=failed (\(failures.count))")
            exit(1)
        }
        print("digest_current_row_height_check=passed")
    }

    private static func usedHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        let container = NSTextContainer(size: NSSize(width: width, height: 10_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}
