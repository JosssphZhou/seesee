import AppKit
import SwiftUI

/// 设置窗口：五组（通用、播放、转写、存放位置、Agent 接入），单列分组框，宽 460，高度随内容。
struct DigestSettingsView: View {
    @StateObject private var model: DigestSettingsModel
    @StateObject private var transcription: TranscriptionModelStatus
    @AppStorage(AppearanceSetting.defaultsKey) private var appearance: AppearanceSetting = .system
    @AppStorage(BoardArchivedColumnSetting.defaultsKey) private var showsArchivedColumn = false
    // 和播放控制条上的胶囊读写同一个键，默认开。
    @AppStorage(SponsorSkipPreference.key) private var skipSponsorSegments = true

    static let width: CGFloat = 460

    init(
        model: DigestSettingsModel? = nil,
        mediaFolder: URL? = nil,
        transcription: TranscriptionModelStatus? = nil
    ) {
        _model = StateObject(wrappedValue: model ?? DigestSettingsModel(mediaFolder: mediaFolder))
        _transcription = StateObject(wrappedValue: transcription ?? TranscriptionModelStatus())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(DigestSettingsCopy.generalSectionTitle) {
                row {
                    label(AppearanceSetting.label)
                    AppearanceSegments(selection: $appearance)
                }
                hairline
                row {
                    Toggle(isOn: $showsArchivedColumn) { label(DigestSettingsCopy.archivedColumnLabel) }
                        .toggleStyle(SettingsSwitchStyle())
                }
            }
            .onChange(of: appearance) { setting in
                OpenMyChrome.applyAppearance(setting)
            }
            section(DigestSettingsCopy.playbackSectionTitle) {
                row {
                    Toggle(isOn: $skipSponsorSegments) { label(DigestSettingsCopy.sponsorSkipLabel) }
                        .toggleStyle(SettingsSwitchStyle())
                }
            }
            section(DigestSettingsCopy.transcriptionSectionTitle) {
                row {
                    label(DigestSettingsCopy.transcriptionModelLabel)
                    transcriptionStatus
                }
            }
            if model.mediaFolder != nil {
                section(DigestSettingsCopy.dataSectionTitle) {
                    mediaFolderRows
                }
            }
            section(DigestSettingsCopy.agentSectionTitle) {
                row {
                    label(DigestSettingsCopy.claudeCodeLabel)
                    SettingsCopyButton(title: DigestSettingsCopy.copyCommand) {
                        AgentSetupSnippet.claudeCode(executablePath: AgentSetupSnippet.executablePath())
                    }
                }
                hairline
                row {
                    label(DigestSettingsCopy.codexLabel)
                    SettingsCopyButton(title: DigestSettingsCopy.copyConfig) {
                        AgentSetupSnippet.codex(executablePath: AgentSetupSnippet.executablePath())
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(width: Self.width, alignment: .leading)
        .background(OpenMyChrome.canvas)
        .navigationTitle(DigestSettingsCopy.windowTitle)
        .task { await transcription.refresh() }
    }

    // MARK: 转写模型

    @ViewBuilder
    private var transcriptionStatus: some View {
        switch transcription.state {
        case .notInstalled:
            statusText(DigestSettingsCopy.transcriptionNotInstalled)
            SettingsButton(title: DigestSettingsCopy.transcriptionDownload, action: transcription.download)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                SettingsProgressBar(fraction: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OpenMyChrome.muted)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        case .available:
            dotStatus(DigestSettingsCopy.transcriptionAvailable, color: OpenMyChrome.success)
        case .failed:
            dotStatus(DigestSettingsCopy.transcriptionFailed, color: OpenMyChrome.rec)
            SettingsButton(title: DigestSettingsCopy.transcriptionRetry, action: transcription.download)
        case .unsupportedSystem:
            statusText(DigestSettingsCopy.transcriptionUnsupported)
        }
    }

    // MARK: 存放位置

    @ViewBuilder
    private var mediaFolderRows: some View {
        row {
            label(DigestSettingsCopy.mediaLabel)
                .fixedSize()
            pathText(model.mediaPathText, color: OpenMyChrome.muted)
            SettingsButton(title: DigestSettingsCopy.revealTitle, action: model.revealMediaFolder)
            SettingsButton(title: MediaFolderCopy.changeButton) { model.onChangeMediaFolder?() }
        }
        if model.isMediaFolderDisconnected {
            hairline
            hintRow(MediaFolderCopy.disconnected)
        }
        if model.previousMediaFolder != nil {
            hairline
            row {
                Text(MediaFolderCopy.previousFolderKept)
                    .font(.system(size: 12))
                    .foregroundStyle(OpenMyChrome.muted)
                    .fixedSize()
                pathText(model.previousMediaPathText, color: OpenMyChrome.faint)
                SettingsButton(title: MediaFolderCopy.revealInFinder, action: model.revealPreviousMediaFolder)
            }
        }
        if let progress = model.mediaFolderMoveProgress {
            hairline
            row {
                Text(progress.text)
                    .font(.system(size: 12))
                    .foregroundStyle(OpenMyChrome.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsProgressBar(fraction: progress.total > 0 ? Double(progress.completed) / Double(progress.total) : 0)
            }
            .accessibilityElement(children: .combine)
        }
        if let failure = model.mediaFolderMoveFailure {
            hairline
            hintRow(failure)
        }
    }

    // MARK: 版式

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OpenMyChrome.muted)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                content()
            }
            .padding(1)
            .background(OpenMyChrome.card, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusMd, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OpenMyChrome.radiusMd, style: .continuous)
                    .strokeBorder(OpenMyChrome.hair)
            }
        }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            content()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private var hairline: some View {
        Rectangle()
            .fill(OpenMyChrome.hair)
            .frame(height: 1)
    }

    /// 行名占满剩下的宽度，把右边的控件推到行尾。
    private func label(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(OpenMyChrome.ink)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(OpenMyChrome.muted)
            .fixedSize()
    }

    private func dotStatus(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            StatusDot(color: color)
            statusText(text)
        }
        .accessibilityElement(children: .combine)
    }

    /// 句首红点加灰字，用于未连接和搬移失败；长句换行，红点对齐第一行。
    private func hintRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            StatusDot(color: OpenMyChrome.rec)
                .padding(.top, 5)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(OpenMyChrome.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private func pathText(_ path: String, color: Color) -> some View {
        Text(path)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(path)
            .accessibilityLabel(path)
    }
}

// MARK: - 控件

/// 设置页的按钮：11 号半粗体，最小高 24，左右内边距 10，画布底加细线描边。
struct SettingsButton: View {
    let title: String
    /// 按钮文字会临时换掉时，按这段文字留宽，换字时按钮不跟着变宽变窄。
    var widthTemplate: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let widthTemplate {
                    Text(widthTemplate).hidden()
                }
                Text(title)
            }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OpenMyChrome.ink)
                .fixedSize()
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
}

/// 拷贝按钮：点了把文字拷到剪贴板，按钮文字换成「已拷贝」约 1.5 秒再变回来。
struct SettingsCopyButton: View {
    let title: String
    let text: () -> String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    static let feedbackDuration: Duration = .milliseconds(1500)

    var body: some View {
        SettingsButton(title: copied ? DigestSettingsCopy.copied : title, widthTemplate: title) {
            AgentSetupSnippet.copy(text())
            copied = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: Self.feedbackDuration)
                guard !Task.isCancelled else { return }
                copied = false
            }
        }
        .onDisappear { resetTask?.cancel() }
    }
}

/// 外观的三段选择：raise 底的胶囊，选中段深色用 rowPressed，浅色用白。
/// 不用系统分段控件：它的选中色在运行中切外观后会留在旧外观。
private struct AppearanceSegments: View {
    @Binding var selection: AppearanceSetting

    private static let selectedFill = Color(nsColor: NSColor(dark: OpenMyChrome.rowPressedHex, light: OpenMyChrome.lightCardHex))

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppearanceSetting.allCases) { setting in
                let isSelected = setting == selection
                Button {
                    selection = setting
                } label: {
                    Text(setting.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? OpenMyChrome.ink : OpenMyChrome.muted)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Self.selectedFill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(setting.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(OpenMyChrome.raise, in: RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenMyChrome.radiusSm, style: .continuous)
                .strokeBorder(OpenMyChrome.hair)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppearanceSetting.label)
    }
}

/// 设置页的开关：28×16，圆钮 12。开：ink 轨道、canvas 圆钮。
/// 关：rowPressed 轨道；圆钮深色用 ink，浅色用白加一层细阴影。
struct SettingsSwitchStyle: ToggleStyle {
    private static let offKnob = Color(nsColor: NSColor(dark: OpenMyChrome.inkHex, light: OpenMyChrome.lightCardHex))
    private static let offKnobShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .clear
            : NSColor(white: 0, alpha: 0.25)
    })

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    configuration.isOn.toggle()
                }
            } label: {
                track(isOn: configuration.isOn)
            }
            .buttonStyle(.plain)
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private func track(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? OpenMyChrome.ink : OpenMyChrome.rowPressed)
            Circle()
                .fill(isOn ? OpenMyChrome.canvas : Self.offKnob)
                .shadow(color: isOn ? .clear : Self.offKnobShadow, radius: 1, x: 0, y: 1)
                .frame(width: 12, height: 12)
                .padding(2)
        }
        .frame(width: 28, height: 16)
        .contentShape(Capsule())
    }
}

/// 96×4 的进度条：raise 底，ink 填充。转写模型下载和存放位置搬移共用。
private struct SettingsProgressBar: View {
    let fraction: Double

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(OpenMyChrome.raise)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(OpenMyChrome.ink)
                .frame(width: 96 * clamped)
        }
        .frame(width: 96, height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }
}

private struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}
