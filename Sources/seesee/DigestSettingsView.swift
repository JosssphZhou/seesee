import SwiftUI

struct DigestSettingsView: View {
    @StateObject private var model: DigestSettingsModel
    @AppStorage(AppearanceSetting.defaultsKey) private var appearance: AppearanceSetting = .system

    static let width: CGFloat = 460

    init(model: DigestSettingsModel? = nil, mediaFolder: URL? = nil) {
        _model = StateObject(wrappedValue: model ?? DigestSettingsModel(mediaFolder: mediaFolder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(AppearanceSetting.label) {
                Picker(AppearanceSetting.label, selection: $appearance) {
                    ForEach(AppearanceSetting.allCases) { setting in
                        Text(setting.title).tag(setting)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                // 用系统默认的分段控件配色，不继承窗口的墨色 tint：墨色在运行中切外观后选中段会留在旧外观的颜色。
                .tint(nil)
                Spacer(minLength: 0)
            }
            .onChange(of: appearance) { setting in
                OpenMyChrome.applyAppearance(setting)
            }
            if model.mediaFolder != nil {
                Text(DigestSettingsCopy.dataSectionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OpenMyChrome.ink)
                row(DigestSettingsCopy.mediaLabel) {
                    Text(model.mediaPathText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OpenMyChrome.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(model.mediaPathText)
                    Spacer(minLength: 8)
                    secondaryButton(DigestSettingsCopy.revealTitle, action: model.revealMediaFolder)
                    secondaryButton(MediaFolderCopy.changeButton, action: { model.onChangeMediaFolder?() })
                }
                if model.isMediaFolderDisconnected {
                    row("") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MediaFolderCopy.disconnected)
                                .font(.system(size: 12))
                                .foregroundStyle(OpenMyChrome.rec)
                                .accessibilityLabel(MediaFolderCopy.disconnected)
                            Text(model.mediaPathText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(OpenMyChrome.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if model.previousMediaFolder != nil {
                    row("") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MediaFolderCopy.previousFolderKept)
                                .font(.system(size: 12))
                                .foregroundStyle(OpenMyChrome.muted)
                            Text(model.previousMediaPathText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(OpenMyChrome.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(MediaFolderCopy.previousFolderKept) \(model.previousMediaPathText)")
                        Spacer(minLength: 8)
                        secondaryButton(MediaFolderCopy.revealInFinder, action: model.revealPreviousMediaFolder)
                    }
                }
                if let progress = model.mediaFolderMoveProgress {
                    row("") {
                        Text(progress.text)
                            .font(.system(size: 12))
                            .foregroundStyle(OpenMyChrome.muted)
                            .accessibilityLabel(progress.text)
                        Spacer(minLength: 0)
                    }
                }
                if let failure = model.mediaFolderMoveFailure {
                    row("") {
                        Text(failure)
                            .font(.system(size: 12))
                            .foregroundStyle(OpenMyChrome.rec)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(failure)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: Self.width, alignment: .leading)
        .background(OpenMyChrome.canvas)
        .navigationTitle(DigestSettingsCopy.windowTitle)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OpenMyChrome.ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            OpenMyChrome.canvas,
            in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous)
                .strokeBorder(OpenMyChrome.hair)
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(OpenMyChrome.muted)
                .frame(width: 36, alignment: .leading)
            content()
        }
    }
}
