import AppKit
import SwiftUI

struct DigestSearchBar: View {
    var query: String
    var onQueryChange: (String) -> Void
    let matchCount: Int
    let activeIndex: Int?
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OpenMyChrome.muted)
            TextField("搜索字幕", text: Binding(get: { query }, set: onQueryChange))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(OpenMyChrome.ink)
                .onSubmit { step(1) }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(countLabel)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(OpenMyChrome.muted)
                    .frame(minWidth: 28, alignment: .trailing)
                Button(action: { step(-1) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: DigestBookChrome.minActionHit, height: DigestBookChrome.minActionHit)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OpenMyChrome.ink)
                .disabled(matchCount == 0)
                .help("上一个命中")
                Button(action: { step(1) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: DigestBookChrome.minActionHit, height: DigestBookChrome.minActionHit)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OpenMyChrome.ink)
                .disabled(matchCount == 0)
                .help("下一个命中")
                Button(action: { onQueryChange("") }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OpenMyChrome.muted)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(OpenMyChrome.raise, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous)
                .strokeBorder(OpenMyChrome.hair)
        }
        .onExitCommand { onQueryChange("") }
    }

    private var countLabel: String {
        guard matchCount > 0, let activeIndex else { return "0/0" }
        return "\(activeIndex + 1)/\(matchCount)"
    }
}

struct DigestBookToolbar: View {
    var query: String
    var onQueryChange: (String) -> Void
    let matchCount: Int
    let activeIndex: Int?
    let step: (Int) -> Void

    var body: some View {
        DigestSearchBar(
            query: query,
            onQueryChange: onQueryChange,
            matchCount: matchCount,
            activeIndex: activeIndex,
            step: step
        )
        .frame(minWidth: 0)
        .padding(.horizontal, DigestBookChrome.headerHorizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

func sidePaneEmptyState(title: String, detail: String) -> some View {
    VStack(spacing: 8) {
        Spacer(minLength: 0)
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
        Text(detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
        Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
