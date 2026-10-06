import SwiftUI

/// 下载进度圆环：缩略图、右侧等待画面和播放器上的预览标记共用同一个圆环，只是大小不同。
/// `fraction` 为 nil 时还没有百分比，转一段短弧；`pulsing` 时满格慢慢明暗（已到 100%，还在收尾）。
/// 系统打开「减少动态效果」时不转也不明暗。
/// 圆环用所在位置的前景色：画面和缩略图上是白色，控制条里跟着外观走。
struct DownloadProgressRing: View {
    var fraction: Double?
    var diameter: CGFloat
    var lineWidth: CGFloat
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(.foreground.opacity(0.22), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(.foreground, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(fraction > 0.002 ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
                    .modifier(DownloadRingPulse(active: pulsing && !reduceMotion))
            } else {
                DownloadRingSpinner(lineWidth: lineWidth, animated: !reduceMotion)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// 还没有百分比时转动的短弧，约 1.1 秒一圈。
private struct DownloadRingSpinner: View {
    let lineWidth: CGFloat
    let animated: Bool

    var body: some View {
        if animated {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.1) / 1.1
                arc.rotationEffect(.degrees(turn * 360 - 90))
            }
        } else {
            arc.rotationEffect(.degrees(-90))
        }
    }

    private var arc: some View {
        Circle()
            .inset(by: lineWidth / 2)
            .trim(from: 0, to: 0.28)
            .stroke(.foreground, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}

/// 满格以后慢慢明暗：1.4 秒变暗、1.4 秒变亮。
private struct DownloadRingPulse: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { context in
                let phase = (cos(context.date.timeIntervalSinceReferenceDate * .pi / 1.4) + 1) / 2
                content.opacity(0.4 + 0.6 * phase)
            }
        } else {
            content
        }
    }
}

/// 队列缩略图上的下载状态：压暗一层，中间一个小圆环。
struct DownloadThumbnailOverlay: View {
    let display: DownloadProgressDisplay.Model

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            DownloadProgressRing(
                fraction: display.phase == .preparing ? nil : display.ringFraction,
                diameter: 24,
                lineWidth: 2.5,
                pulsing: display.phase == .finishing
            )
            .foregroundStyle(.white)
        }
    }
}

/// 右侧等待画面：大圆环，中间是百分比，下面是标题和一行速度、剩余时间。
struct DownloadWaitingStack: View {
    let display: DownloadProgressDisplay.Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                DownloadProgressRing(
                    fraction: display.phase == .preparing ? nil : display.ringFraction,
                    diameter: 72,
                    lineWidth: 3,
                    pulsing: display.phase == .finishing
                )
                .foregroundStyle(.white)
                if display.phase == .preparing {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                } else {
                    DownloadPercentText(value: Double(display.percent ?? 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: display.percent)
                        .modifier(DownloadRingPulse(active: display.phase == .finishing && !reduceMotion))
                }
            }
            .padding(.bottom, 16)

            Text(display.paneTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            // 速度行没有读数时整行隐去但保留高度，标题不上下跳。
            Text(display.paneDetail ?? " ")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .opacity(display.paneDetail == nil ? 0 : 1)
                .padding(.top, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let percent = display.phase == .downloading ? display.percent.map { "\($0)%" } : nil
        return [display.paneTitle, percent, display.paneDetail].compactMap { $0 }.joined(separator: "，")
    }
}

/// 圆环中间的百分比：跟着圆环一起平滑数上去。
private struct DownloadPercentText: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int(value.rounded(.down)))")
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
            Text("%")
                .font(.system(size: 11, weight: .semibold))
                .opacity(0.6)
        }
        .foregroundStyle(.white)
    }
}

/// 播放器控制条里的预览标记：小圆环加「预览 62%」，和倍速胶囊用同一种底色。
struct DownloadPreviewBadge: View {
    let text: String
    let fraction: Double?

    var body: some View {
        HStack(spacing: 6) {
            DownloadProgressRing(fraction: fraction, diameter: 12, lineWidth: 1.8)
            Text(text)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(OpenMyChrome.ink)
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 26)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// 每条下载的进度记录（见 `DownloadProgressDisplay.Track`）：队列行、缩略图、右侧和预览标记读同一份，彼此对得上。
/// 只在界面层记，不写进队列。
@MainActor
enum DownloadProgressMemory {
    private static var tracks: [UUID: DownloadProgressDisplay.Track] = [:]

    @discardableResult
    static func display(for item: WatchItem, isPreviewPlayable: Bool) -> DownloadProgressDisplay.Model {
        let track = DownloadProgressDisplay.advance(
            tracks[item.id],
            state: item.state,
            progress: item.progress,
            progressLabel: item.progressLabel,
            isPreviewPlayable: isPreviewPlayable
        )
        tracks[item.id] = track
        return DownloadProgressDisplay.model(
            state: item.state,
            progress: item.progress,
            progressLabel: item.progressLabel,
            isPreviewPlayable: isPreviewPlayable,
            track: track
        )
    }

    /// 队列每变一次就把所有条目推进一遍：屏幕外不渲染的行也不漏读数，记录不断片。
    static func observe(_ items: [WatchItem], isPreviewPlayable: (UUID) -> Bool) {
        for item in items where item.state != .ready || tracks[item.id] != nil {
            display(for: item, isPreviewPlayable: isPreviewPlayable(item.id))
        }
        // 下载中被删掉的条目不再出现在队列里，它的记录一并清掉。
        let present = Set(items.map(\.id))
        tracks = tracks.filter { present.contains($0.key) }
    }
}
