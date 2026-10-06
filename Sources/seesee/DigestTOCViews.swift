import SwiftUI

/// 字幕流顶部的目录：折叠时一行「目录 · N 章 · 时长」，展开后每章一行时间和标题，点一章跳过去播放。
struct DigestTOCBanner: View {
    let chapters: [VideoChapter]
    let duration: Double?
    let isExpanded: Bool
    let currentTime: Double
    let timeColumnWidth: CGFloat
    let onToggleExpand: () -> Void
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
            if isExpanded {
                expandedBody
            }
        }
    }

    private var title: String {
        DigestTOCCopy.collapsedTitle(chapterCount: chapters.count, duration: duration)
    }

    private var collapsedRow: some View {
        Button(action: onToggleExpand) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OpenMyChrome.ink)
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OpenMyChrome.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .frame(minHeight: DigestBookChrome.minActionHit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DigestBookHitKey.self,
                    value: ["toc": proxy.frame(in: .named("digest-book-page"))]
                )
            }
        )
        .accessibilityLabel(title)
        .accessibilityHint(isExpanded ? "收起目录" : "展开目录")
    }

    private var expandedBody: some View {
        let current = DigestTOCChapters.currentIndex(at: currentTime, in: chapters)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                chapterRow(chapter, isCurrent: current == index)
            }
        }
        .padding(.bottom, 8)
    }

    private func chapterRow(_ chapter: VideoChapter, isCurrent: Bool) -> some View {
        Button {
            onSeek(chapter.startTime)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(DigestTimecode.format(chapter.startTime))
                    .font(.system(size: DigestCueDisplay.originalSize).monospacedDigit())
                    .foregroundStyle(isCurrent ? OpenMyChrome.ink : OpenMyChrome.muted)
                    .frame(width: timeColumnWidth, alignment: .trailing)
                Text(chapter.title)
                    .font(.system(size: DigestCueDisplay.translationSize, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(OpenMyChrome.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("跳到这一章")
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DigestBookHitKey.self,
                    value: ["toc-chapter-\(chapter.id)": proxy.frame(in: .named("digest-book-page"))]
                )
            }
        )
    }
}
