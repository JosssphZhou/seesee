import SwiftUI

// YouTube / X 官方标志路径取自 Simple Icons 16.32.0（CC0-1.0）。

struct SourceBrandMark: View {
    let sourceName: String

    var body: some View {
        switch QueueRowMeta.sourceMark(for: sourceName) {
        case .youtube:
            youtubeMark
        case .bilibili:
            bilibiliMark
        case .xiaohongshu:
            xiaohongshuMark
        case .x:
            xMark
        case .unknown:
            // 跟随所在行的前景色：正常行是次要灰，失败行随警示色一起变。
            Circle()
                .fill(.foreground)
                .opacity(0.7)
                .frame(width: 6, height: 6)
        }
    }

    private var youtubeMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                .fill(Color(red: 1, green: 0, blue: 0))
            Path { path in
                path.move(to: CGPoint(x: 5.57, y: 2.89))
                path.addLine(to: CGPoint(x: 5.57, y: 7.11))
                path.addLine(to: CGPoint(x: 9.23, y: 5.00))
                path.closeSubpath()
            }
            .fill(Color.white)
        }
        .frame(width: 14, height: 10)
    }

    private var bilibiliMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                .fill(OpenMyChrome.muted)
                .frame(width: 12, height: 8)
                .offset(y: 1)
            Path { path in
                path.move(to: CGPoint(x: 3.2, y: 2.4))
                path.addLine(to: CGPoint(x: 5.2, y: 0.4))
                path.move(to: CGPoint(x: 8.8, y: 2.4))
                path.addLine(to: CGPoint(x: 6.8, y: 0.4))
            }
            .stroke(OpenMyChrome.muted, lineWidth: 1.2)
            HStack(spacing: 2.2) {
                Capsule()
                    .fill(OpenMyChrome.canvas)
                    .frame(width: 1.6, height: 3.2)
                Capsule()
                    .fill(OpenMyChrome.canvas)
                    .frame(width: 1.6, height: 3.2)
            }
            .offset(y: 1.2)
        }
        .frame(width: 12, height: 12)
    }

    private var xiaohongshuMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                .fill(OpenMyChrome.muted)
            Path { path in
                path.move(to: CGPoint(x: 3.2, y: 2.4))
                path.addLine(to: CGPoint(x: 6, y: 3.4))
                path.addLine(to: CGPoint(x: 8.8, y: 2.4))
                path.addLine(to: CGPoint(x: 8.8, y: 9.4))
                path.addLine(to: CGPoint(x: 6, y: 8.4))
                path.addLine(to: CGPoint(x: 3.2, y: 9.4))
                path.closeSubpath()
                path.move(to: CGPoint(x: 6, y: 3.4))
                path.addLine(to: CGPoint(x: 6, y: 8.4))
            }
            .stroke(OpenMyChrome.canvas, lineWidth: 1)
        }
        .frame(width: 12, height: 12)
    }

    private var xMark: some View {
        xLogoPath
            .fill(OpenMyChrome.ink)
            .frame(width: 12, height: 12)
    }

    /// Simple Icons 的 X 字标：外轮廓 + 反向缠绕的内部子路径，nonzero 填充后中间镂空。
    private var xLogoPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 14.234, y: 10.162))
        path.addLine(to: CGPoint(x: 22.977, y: 0))
        path.addLine(to: CGPoint(x: 20.905, y: 0))
        path.addLine(to: CGPoint(x: 13.314, y: 8.824))
        path.addLine(to: CGPoint(x: 7.251, y: 0))
        path.addLine(to: CGPoint(x: 0.258, y: 0))
        path.addLine(to: CGPoint(x: 9.426, y: 13.343))
        path.addLine(to: CGPoint(x: 0.258, y: 24))
        path.addLine(to: CGPoint(x: 2.33, y: 24))
        path.addLine(to: CGPoint(x: 10.346, y: 14.682))
        path.addLine(to: CGPoint(x: 16.749, y: 24))
        path.addLine(to: CGPoint(x: 23.742, y: 24))
        path.closeSubpath()

        path.move(to: CGPoint(x: 11.397, y: 13.461))
        path.addLine(to: CGPoint(x: 10.468, y: 12.132))
        path.addLine(to: CGPoint(x: 3.076, y: 1.56))
        path.addLine(to: CGPoint(x: 6.258, y: 1.56))
        path.addLine(to: CGPoint(x: 12.223, y: 10.092))
        path.addLine(to: CGPoint(x: 13.152, y: 11.421))
        path.addLine(to: CGPoint(x: 20.906, y: 22.511))
        path.addLine(to: CGPoint(x: 17.724, y: 22.511))
        path.closeSubpath()

        return path.applying(CGAffineTransform(scaleX: 0.5, y: 0.5))
    }
}
