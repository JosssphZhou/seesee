import SwiftUI

/// 封面铺满外层给的框，比例不同时多出的部分裁掉。
/// 外层由 `Color.clear` 定尺寸，图片放在 overlay 里，图片的理想尺寸不会往外报，比 16:9 宽的封面也撑不开卡片。
struct ThumbnailFill: View {
    let image: NSImage

    var body: some View {
        Color.clear
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
    }
}
