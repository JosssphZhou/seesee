import AVKit
import MediaPlayer
import SwiftUI
import os.log

private let playbackHandoffLog = OSLog(subsystem: "ai.openmy.seesee", category: "progressive-playback")

final class PlayerSubtitleOverlayView: NSView {
    private let sourceTextField = NSTextField(labelWithString: "")
    private let translationTextField = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    /// 每行一条贴身底条，对齐原生字幕的观感。
    private let sourcePill = NSView()
    private let translationPill = NSView()
    private(set) var presentation: VideoSubtitlePresentation?
    private var animationGeneration = 0
    private var surfaceWidth: CGFloat = 1
    private var bottomConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?

    var displayedText: String? { presentation?.text }
    var displayedLines: [String] {
        [sourceTextField, translationTextField]
            .filter { !$0.isHidden && !$0.stringValue.isEmpty }
            .map(\.stringValue)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func install(in view: NSView) {
        view.addSubview(self, positioned: .above, relativeTo: nil)
        let bottom = bottomAnchor.constraint(
            equalTo: view.bottomAnchor,
            constant: -SubtitleOverlayLayout.defaultBottomInset
        )
        let width = widthAnchor.constraint(equalToConstant: 1)
        width.priority = .defaultHigh
        bottomConstraint = bottom
        widthConstraint = width
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottom,
            width,
            leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: SubtitleOverlayLayout.surfaceMargin
            ),
            trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -SubtitleOverlayLayout.surfaceMargin
            ),
            widthAnchor.constraint(lessThanOrEqualToConstant: SubtitleOverlayLayout.maxOverlayWidth)
        ])
        updateForSurfaceWidth(max(view.bounds.width, 1))
    }

    func setControlsVisible(_ visible: Bool) {
        bottomConstraint?.constant = -SubtitleOverlayLayout.overlayBottomInset(controlsVisible: visible)
    }

    func updateForSurfaceWidth(_ width: CGFloat) {
        if width != surfaceWidth { finishCrossFade() }
        surfaceWidth = width
        applyLayoutDecision()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        applyLayoutDecision()
    }

    func setPresentation(_ presentation: VideoSubtitlePresentation?, animated: Bool) {
        guard self.presentation != presentation else { return }
        let chrome = SubtitleOverlayChromeAnimation.resolve(from: self.presentation, to: presentation)
        self.presentation = presentation
        animationGeneration &+= 1
        let generation = animationGeneration
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if let presentation {
            // 换句走纯渐隐：先把旧句拍成快照，新句布局就位后旧句快照在原位淡出。
            let outgoing: OutgoingSnapshot? = (chrome == .replace && shouldAnimate && !isHidden && window != nil)
                ? captureOutgoingSnapshot()
                : nil
            if outgoing == nil { finishCrossFade() }
            applyLineTexts(from: presentation)
            isHidden = false
            applyLayoutDecision()
            needsLayout = true
            if chrome == .fadeIn, shouldAnimate {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animator().alphaValue = 1
                }
            } else {
                alphaValue = 1
                if let outgoing {
                    runCrossFade(from: outgoing)
                }
            }
            return
        }

        guard chrome == .fadeOut, shouldAnimate, !isHidden else {
            finishCrossFade()
            alphaValue = 0
            isHidden = true
            clearText()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self,
                  self.animationGeneration == generation,
                  self.presentation == nil else { return }
            self.isHidden = true
            self.clearText()
        })
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // 原生样式：整块大底框退役，每行文字各自一条贴身底条（见下方 pill 装配）。
        layer?.backgroundColor = NSColor.clear.cgColor
        // 旧句快照挂在本层上，比新句宽或高时也不能被裁掉。
        if #available(macOS 14.0, *) {
            clipsToBounds = false
        } else {
            layer?.masksToBounds = false
        }
        alphaValue = 0
        isHidden = true

        for textField in [sourceTextField, translationTextField] {
            textField.textColor = .white
            textField.alignment = .center
            textField.maximumNumberOfLines = SubtitleOverlayLayout.maximumLineCount(wraps: false)
            textField.lineBreakMode = SubtitleOverlayLayout.lineBreakMode(wraps: false)
            textField.usesSingleLineMode = true
            textField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            textField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }

        for (pill, field) in [(sourcePill, sourceTextField), (translationPill, translationTextField)] {
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
            pill.layer?.cornerRadius = 8
            field.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
                field.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
                field.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
                field.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4)
            ])
        }

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.wantsLayer = true
        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 4
        textStack.addArrangedSubview(sourcePill)
        textStack.addArrangedSubview(translationPill)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    /// 换句交叉渐隐时长：旧句与新句同时处于半透明的时间尽量短，读字不糊。
    private static let crossFadeDuration: TimeInterval = 0.12
    private static let crossFadeTiming = CAMediaTimingFunction(name: .easeInEaseOut)
    private weak var outgoingLayer: CALayer?

    private struct OutgoingSnapshot {
        let image: CGImage
        /// 换句前旧句在宿主视图里的位置；浮层以底边和水平中线固定，旧句必须原地淡出。
        let frameInHost: NSRect
    }

    private func captureOutgoingSnapshot() -> OutgoingSnapshot? {
        guard let host = superview,
              textStack.frame.width > 0,
              let rep = textStack.bitmapImageRepForCachingDisplay(in: textStack.bounds) else { return nil }
        textStack.cacheDisplay(in: textStack.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        return OutgoingSnapshot(image: image, frameInHost: host.convert(textStack.bounds, from: textStack))
    }

    /// 纯渐隐：旧句原地淡出、新句原地淡入，零位移。
    /// 新句的宽高、行数直接到位，不做尺寸动画；只有两句的透明度在变。
    private func runCrossFade(from outgoing: OutgoingSnapshot) {
        guard let host = superview, let overlayLayer = layer, let stackLayer = textStack.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.layoutSubtreeIfNeeded()
        outgoingLayer?.removeFromSuperlayer()

        let ghost = CALayer()
        ghost.contents = outgoing.image
        ghost.contentsScale = window?.backingScaleFactor ?? 2
        ghost.frame = convert(outgoing.frameInHost, from: host)
        overlayLayer.addSublayer(ghost)
        outgoingLayer = ghost
        CATransaction.commit()

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = Self.crossFadeDuration
        fadeOut.timingFunction = Self.crossFadeTiming
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        ghost.opacity = 0
        ghost.add(fadeOut, forKey: "fade-out")

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = Self.crossFadeDuration
        fadeIn.timingFunction = Self.crossFadeTiming
        stackLayer.add(fadeIn, forKey: "fade-in")

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.crossFadeDuration) { [weak ghost] in
            ghost?.removeFromSuperlayer()
        }
    }

    /// 不走交叉渐隐的变化（直接替换、立即隐藏、宿主宽度变化）要立刻到位：
    /// 快照按换句前的宿主位置摆放，浮层重新居中后会偏离原位，所以连同新句淡入一起收掉。
    private func finishCrossFade() {
        outgoingLayer?.removeFromSuperlayer()
        outgoingLayer = nil
        textStack.layer?.removeAnimation(forKey: "fade-in")
    }

    private func applyLineTexts(from presentation: VideoSubtitlePresentation) {
        let lines = VideoSubtitlePresentation.displayLines(from: presentation.text)
        // 中西文垫窄空格是全局排版规则，浮层与右栏一致。
        sourceTextField.stringValue = SubtitleSentenceBlocks.withCJKLatinSpacing(lines.first ?? "")
        translationTextField.stringValue = SubtitleSentenceBlocks.withCJKLatinSpacing(lines.dropFirst().joined(separator: " "))
        sourceTextField.isHidden = sourceTextField.stringValue.isEmpty
        translationTextField.isHidden = translationTextField.stringValue.isEmpty
        sourcePill.isHidden = sourceTextField.isHidden
        translationPill.isHidden = translationTextField.isHidden
    }

    private func resolvedSurfaceWidth() -> CGFloat {
        if let hostWidth = superview?.bounds.width, hostWidth > 1 {
            return hostWidth
        }
        if bounds.width > 1 {
            return bounds.width
        }
        return max(surfaceWidth, 1)
    }

    private func applyLayoutDecision() {
        let texts = displayedLines
        guard !texts.isEmpty else { return }
        let width = resolvedSurfaceWidth()
        if width != surfaceWidth { finishCrossFade() }
        surfaceWidth = width
        let decision = SubtitleOverlayLayout.resolve(lines: texts, surfaceWidth: surfaceWidth)
        widthConstraint?.constant = decision.overlayWidth
        let fields = [sourceTextField, translationTextField].filter {
            !$0.isHidden && !$0.stringValue.isEmpty
        }
        for (field, line) in zip(fields, decision.lines) {
            field.font = SubtitleOverlayLayout.roundedFont(size: line.fontSize)
            field.maximumNumberOfLines = SubtitleOverlayLayout.maximumLineCount(wraps: line.wraps)
            field.lineBreakMode = SubtitleOverlayLayout.lineBreakMode(wraps: line.wraps)
            field.usesSingleLineMode = !line.wraps
            field.preferredMaxLayoutWidth = decision.contentWidth
        }
    }

    private func clearText() {
        sourceTextField.stringValue = ""
        translationTextField.stringValue = ""
        sourceTextField.isHidden = true
        translationTextField.isHidden = true
        sourcePill.isHidden = true
        translationPill.isHidden = true
        sourceTextField.preferredMaxLayoutWidth = 0
        translationTextField.preferredMaxLayoutWidth = 0
    }
}

final class FloatingVideoPlayerView: AVPlayerView {
    var onVolumeScroll: ((Double) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onReturnToMainWindow: (() -> Void)?
    private let volumeScrollInterpreter = PlayerVolumeScrollInterpreter()
    private let returnButton = NSButton()
    private let titleBackdrop = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let originalTitleField = NSTextField(labelWithString: "")
    private let subtitleOverlay = PlayerSubtitleOverlayView()
    private var hoverTrackingArea: NSTrackingArea?

    var displayedSubtitleText: String? { subtitleOverlay.displayedText }
    var displayedSubtitleLines: [String] { subtitleOverlay.displayedLines }
    var subtitleOverlayAlpha: CGFloat { subtitleOverlay.alphaValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        subtitleOverlay.install(in: self)
        configureReturnButton()
        configureTitle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        subtitleOverlay.install(in: self)
        configureReturnButton()
        configureTitle()
    }

    override func layout() {
        super.layout()
        subtitleOverlay.updateForSurfaceWidth(bounds.width)
    }

    func setSubtitlePresentation(_ presentation: VideoSubtitlePresentation?, animated: Bool) {
        subtitleOverlay.updateForSurfaceWidth(bounds.width)
        subtitleOverlay.setPresentation(presentation, animated: animated)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        subtitleOverlay.updateForSurfaceWidth(newSize.width)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHoverControlsVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoverControlsVisible(false)
    }

    override func scrollWheel(with event: NSEvent) {
        let adjustment = volumeScrollInterpreter.adjustment(for: event)
        if adjustment != 0 { onVolumeScroll?(adjustment) }
    }

    override func swipe(with event: NSEvent) {
        // Consume swipe momentum for the same reason as scroll-wheel events.
    }

    private func configureReturnButton() {
        let symbol = NSImage(systemSymbolName: "pip.exit", accessibilityDescription: "回到 seesee")
            ?? NSImage(systemSymbolName: "arrow.up.backward.and.arrow.down.forward", accessibilityDescription: "回到 seesee")
        returnButton.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        returnButton.imagePosition = .imageOnly
        returnButton.isBordered = false
        returnButton.contentTintColor = .white
        returnButton.toolTip = "回到 seesee"
        returnButton.setAccessibilityLabel("回到 seesee")
        returnButton.target = self
        returnButton.action = #selector(returnToMainWindow)
        returnButton.translatesAutoresizingMaskIntoConstraints = false
        returnButton.wantsLayer = true
        returnButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        returnButton.layer?.cornerRadius = 15
        returnButton.isHidden = true
        addSubview(returnButton, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            returnButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            returnButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            returnButton.widthAnchor.constraint(equalToConstant: 30),
            returnButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    /// 悬停时左上角显示中文主标题，下面一行小字是原标题，和队列行一样。
    func setTitle(_ title: String, originalTitle: String?) {
        titleField.stringValue = title
        originalTitleField.stringValue = originalTitle ?? ""
        originalTitleField.isHidden = originalTitle == nil
        titleBackdrop.setAccessibilityLabel([title, originalTitle].compactMap { $0 }.joined(separator: "\n"))
    }

    private func configureTitle() {
        titleBackdrop.wantsLayer = true
        titleBackdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        titleBackdrop.layer?.cornerRadius = 10
        titleBackdrop.translatesAutoresizingMaskIntoConstraints = false
        titleBackdrop.isHidden = true
        titleBackdrop.setAccessibilityElement(true)
        titleBackdrop.setAccessibilityRole(.staticText)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .white
        originalTitleField.font = .systemFont(ofSize: 11)
        originalTitleField.textColor = NSColor.white.withAlphaComponent(0.7)
        for field in [titleField, originalTitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.truncatesLastVisibleLine = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [titleField, originalTitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        titleBackdrop.addSubview(stack)
        addSubview(titleBackdrop, positioned: .below, relativeTo: returnButton)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: titleBackdrop.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: titleBackdrop.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: titleBackdrop.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: titleBackdrop.trailingAnchor, constant: -10),
            titleBackdrop.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleBackdrop.trailingAnchor.constraint(lessThanOrEqualTo: returnButton.leadingAnchor, constant: -8)
        ])
    }

    private func setHoverControlsVisible(_ visible: Bool) {
        returnButton.isHidden = !visible
        titleBackdrop.isHidden = !visible || titleField.stringValue.isEmpty
        subtitleOverlay.setControlsVisible(visible)
        onHoverChanged?(visible)
    }

    @objc private func returnToMainWindow() {
        onReturnToMainWindow?()
    }
}

final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()
    var onVolumeScroll: ((Double) -> Void)?
    private var scrollEventMonitor: Any?
    private let volumeScrollInterpreter = PlayerVolumeScrollInterpreter()
    private let subtitleOverlay = PlayerSubtitleOverlayView()

    var displayedSubtitleText: String? { subtitleOverlay.displayedText }
    var displayedSubtitleLines: [String] { subtitleOverlay.displayedLines }
    var subtitleOverlayAlpha: CGFloat { subtitleOverlay.alphaValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpPlayerLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpPlayerLayer()
    }

    private func setUpPlayerLayer() {
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.needsDisplayOnBoundsChange = true
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull()
        ]
        subtitleOverlay.install(in: self)
        updatePlayerLayerFrame()
    }

    override func layout() {
        super.layout()
        updatePlayerLayerFrame()
        subtitleOverlay.updateForSurfaceWidth(bounds.width)
    }

    func setSubtitlePresentation(_ presentation: VideoSubtitlePresentation?, animated: Bool) {
        subtitleOverlay.updateForSurfaceWidth(bounds.width)
        subtitleOverlay.setPresentation(presentation, animated: animated)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePlayerLayerFrame()
        subtitleOverlay.updateForSurfaceWidth(newSize.width)
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updatePlayerLayerFrame()
    }

    private func updatePlayerLayerFrame() {
        // AVPlayerLayer otherwise applies Core Animation's implicit bounds and
        // position animation. During live window growth that makes the video
        // visibly chase its containing view. Update on every AppKit geometry
        // callback and commit the exact new bounds with no animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeScrollEventMonitor()
        guard window != nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  self.shouldConsumeScrollEvent(event, in: window) else { return event }
            self.handleVolumeScroll(event)
            return nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        handleVolumeScroll(event)
    }

    override func swipe(with event: NSEvent) {
        // Consume trackpad swipe phases over the video as well as scroll-wheel
        // phases so momentum cannot escape through SwiftUI's hosting wrapper.
    }

    private func shouldConsumeScrollEvent(_ event: NSEvent, in window: NSWindow) -> Bool {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint), let contentView = window.contentView else { return false }
        let contentPoint = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(contentPoint) else { return false }

        if hitView === self || hitView.isDescendant(of: self) { return true }

        // SwiftUI may report its transparent hosting wrapper as the hit target
        // instead of this representable. Consume that case, but leave sibling
        // controls such as the chapter scroll view alone.
        return self.isDescendant(of: hitView) && !(hitView is NSScrollView)
    }

    private func handleVolumeScroll(_ event: NSEvent) {
        let adjustment = volumeScrollInterpreter.adjustment(for: event)
        if adjustment != 0 { onVolumeScroll?(adjustment) }
    }

    private func removeScrollEventMonitor() {
        guard let scrollEventMonitor else { return }
        NSEvent.removeMonitor(scrollEventMonitor)
        self.scrollEventMonitor = nil
    }

    deinit {
        removeScrollEventMonitor()
    }
}

private final class PlayerVolumeScrollInterpreter {
    private enum Axis {
        case horizontal
        case vertical
    }

    private var lockedAxis: Axis?
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0

    func adjustment(for event: NSEvent) -> Double {
        if event.phase.contains(.began) { reset() }
        guard PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase
        ) else {
            reset()
            return 0
        }

        if event.phase.isEmpty {
            guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) * 0.8 else { return 0 }
            return PlayerVolumeScrollPolicy.adjustment(
                deltaX: 0,
                deltaY: event.scrollingDeltaY,
                isPrecise: event.hasPreciseScrollingDeltas,
                isMomentum: false
            )
        }

        if event.hasPreciseScrollingDeltas {
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY
            if lockedAxis == nil {
                let largestDistance = max(abs(accumulatedX), abs(accumulatedY))
                guard largestDistance >= 0.75 else { return 0 }
                lockedAxis = abs(accumulatedY) >= abs(accumulatedX) * 0.8
                    ? .vertical
                    : .horizontal
            }
        } else {
            lockedAxis = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
                ? .vertical
                : .horizontal
        }

        guard lockedAxis == .vertical else { return 0 }
        return PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            isMomentum: false
        )
    }

    private func reset() {
        lockedAxis = nil
        accumulatedX = 0
        accumulatedY = 0
    }
}

enum PlayerVolumeScrollEventPolicy {
    static func shouldAdjust(
        isPrecise: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) -> Bool {
        guard momentumPhase.isEmpty,
              !phase.contains(.ended),
              !phase.contains(.cancelled) else { return false }

        // Trackpads and Magic Mouse report precise deltas. Only accept those
        // while fingers are actively driving the gesture; phase-less precise
        // events are trailing inertia on some macOS/device combinations.
        guard isPrecise else { return true }
        return phase.contains(.began) || phase.contains(.changed)
    }
}

enum PlayerVolumeScrollPolicy {
    static func adjustment(
        deltaX: Double,
        deltaY: Double,
        isPrecise: Bool,
        isMomentum: Bool
    ) -> Double {
        guard !isMomentum,
              deltaY.isFinite,
              abs(deltaY) > abs(deltaX),
              abs(deltaY) >= 0.05 else { return 0 }

        if isPrecise {
            return min(0.08, max(-0.08, deltaY * 0.006))
        }
        return deltaY > 0 ? 0.05 : -0.05
    }
}

struct PlayerSeekRequest: Equatable {
    let id = UUID()
    let time: Double
    let shouldPlay: Bool
}

struct PlaybackSnapshot: Equatable {
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var isMuted = false
    var volume: Double = PlaybackVolumePreference.load()
    var playbackRate: Double = 1
    var isExternalPlaybackActive = false

    static var empty: PlaybackSnapshot {
        PlaybackSnapshot(playbackRate: PlaybackRatePreference.load())
    }
}

enum NowPlayingInfoBuilder {
    static func make(
        title: String,
        author: String,
        snapshot: PlaybackSnapshot
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "seesee" : title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.playbackRate
        ]
        if !author.isEmpty {
            info[MPMediaItemPropertyArtist] = author
        }
        if snapshot.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        }
        return info
    }
}

enum HardwareMediaKeyAction: Equatable {
    case togglePlayback
    case skip(Double)
}

enum HardwareMediaKeyEventPolicy {
    private static let auxiliaryControlButtonsSubtype = 8
    private static let keyDownState = 0xA

    static func action(subtype: Int, data1: Int) -> HardwareMediaKeyAction? {
        guard subtype == auxiliaryControlButtonsSubtype else { return nil }

        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0x0000FF00) >> 8
        let isRepeat = (keyFlags & 0x1) != 0
        guard keyState == keyDownState, !isRepeat else { return nil }

        switch keyCode {
        case 16:
            return .togglePlayback
        case 17, 19:
            return .skip(10)
        case 18, 20:
            return .skip(-10)
        default:
            return nil
        }
    }
}

final class SystemMediaController {
    static let shared = SystemMediaController()

    private var isStarted = false
    private var title = "seesee"
    private var author = ""
    private var snapshot = PlaybackSnapshot.empty
    private weak var activePlayer: AVPlayer?
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
    }

    func activate(player: AVPlayer) {
        guard isStarted else { return }
        if activePlayer === player, !commandTargets.isEmpty {
            publish()
            return
        }

        tearDownSession(clearNowPlayingInfo: true)
        activePlayer = player
        // macOS exposes the process-wide command center rather than
        // MPNowPlayingSession. Install the handlers only once there is a real
        // AVPlayer to command, then publish its matching playback state.
        installCommands(on: MPRemoteCommandCenter.shared())
        publish()
    }

    func deactivate(player: AVPlayer) {
        guard activePlayer === player else { return }
        tearDownSession(clearNowPlayingInfo: true)
    }

    private func installCommands(on commands: MPRemoteCommandCenter) {
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true
        commands.skipForwardCommand.isEnabled = true
        commands.skipBackwardCommand.isEnabled = true
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]

        addTarget(to: commands.playCommand) {
            PlaybackCommandCenter.shared.play()
        }
        addTarget(to: commands.pauseCommand) {
            PlaybackCommandCenter.shared.pause()
        }
        addTarget(to: commands.togglePlayPauseCommand) {
            PlaybackCommandCenter.shared.togglePlayback()
        }
        // Mac keyboards report the previous/next media buttons as track
        // commands, while Control Center can report explicit skip commands.
        addTarget(to: commands.previousTrackCommand) {
            PlaybackCommandCenter.shared.skip(by: -10)
        }
        addTarget(to: commands.nextTrackCommand) {
            PlaybackCommandCenter.shared.skip(by: 10)
        }
        addTarget(to: commands.skipBackwardCommand) {
            PlaybackCommandCenter.shared.skip(by: -10)
        }
        addTarget(to: commands.skipForwardCommand) {
            PlaybackCommandCenter.shared.skip(by: 10)
        }
    }

    private func addTarget(to command: MPRemoteCommand, action: @escaping () -> Void) {
        let target = command.addTarget { _ in
            // Media-key handlers may arrive off the main thread. Consume the
            // command immediately, then perform AVPlayer work on the main queue.
            DispatchQueue.main.async {
                action()
            }
            return .success
        }
        commandTargets.append((command, target))
    }

    func setItem(title: String, author: String) {
        self.title = title
        self.author = author
        publish()
    }

    func update(_ snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot
        publish()
    }

    func stop() {
        snapshot.isPlaying = false
        isStarted = false
        tearDownSession(clearNowPlayingInfo: true)
    }

    private func publish() {
        guard isStarted, activePlayer != nil else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = NowPlayingInfoBuilder.make(
            title: title,
            author: author,
            snapshot: snapshot
        )
        center.playbackState = snapshot.isPlaying ? .playing : .paused
    }

    private func tearDownSession(clearNowPlayingInfo: Bool) {
        for entry in commandTargets {
            entry.command.removeTarget(entry.target)
        }
        commandTargets.removeAll()

        if clearNowPlayingInfo {
            let center = MPNowPlayingInfoCenter.default()
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
        }
        activePlayer = nil
    }
}

enum PlaybackRatePolicy {
    static let minimum = 1.0
    static let maximum = 2.5
    static let supportedRates = (10...25).map { Double($0) / 10 }

    static func normalized(_ rate: Double) -> Double {
        guard rate.isFinite else { return minimum }
        let tenths = Int((rate * 10).rounded())
        return Double(min(max(tenths, Int(minimum * 10)), Int(maximum * 10))) / 10
    }

    static func adjusted(_ current: Double, by amount: Double) -> Double {
        normalized(current + amount)
    }
}

enum PlaybackRatePreference {
    private static let key = "playbackRate"

    static func load(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil else { return PlaybackRatePolicy.minimum }
        return PlaybackRatePolicy.normalized(defaults.double(forKey: key))
    }

    static func save(_ rate: Double, to defaults: UserDefaults = .standard) {
        defaults.set(PlaybackRatePolicy.normalized(rate), forKey: key)
    }
}

enum PlaybackAudioPolicy {
    // seesee is primarily speech, and AVFoundation documents time-domain
    // processing as the lower-cost voice algorithm. Unlike the spectral music
    // processor, it can follow interactive rate changes without rebuilding a
    // large analysis window and creating an audible hole.
    static let timePitchAlgorithm: AVAudioTimePitchAlgorithm = .timeDomain

    // Waiting for AVPlayer's network stall predictor after a rate change only
    // adds latency and cannot improve buffering for local files. The online
    // preview played while a download is still running uses the same setting
    // (as upstream does); it starts sooner but stops on a stall.
    static let waitsToMinimizeStalling = false

    // 主窗口、全屏和悬浮小窗共用这一个播放器，在这里统一配置。
    static func makePlayer(playing playerItem: AVPlayerItem) -> AVPlayer {
        playerItem.audioTimePitchAlgorithm = timePitchAlgorithm
        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = waitsToMinimizeStalling
        // macOS 上默认是 false，播放时屏幕会按系统时间熄灭；设为 true 后
        // AVPlayer 只在播放期间阻止熄屏，暂停或停止后自动恢复系统设置。
        player.preventsDisplaySleepDuringVideoPlayback = true
        return player
    }
}

/// 下载中先播在线预览，完整画质下完后在同一个播放器里换成本地文件：从哪里接着播、要不要接着播。
enum PlaybackHandoffPolicy {
    struct Plan: Equatable {
        let time: Double
        let shouldPlay: Bool
    }

    /// 时间依次取：进行中的跳转目标、还没完成的续播位置、播放器当前时间；都不可用时从 0 开始。
    /// 正在播或在缓冲等待（不是暂停）就接着播；已经播到结尾不再开播。
    static func plan(
        playerTime: Double,
        pendingSeekTime: Double?,
        pendingResumeTime: Double?,
        isPaused: Bool,
        reachedEnd: Bool
    ) -> Plan {
        let candidates = [pendingSeekTime, pendingResumeTime, playerTime]
        let time = candidates.lazy.compactMap { $0 }.first { $0.isFinite } ?? 0
        return Plan(time: max(0, time), shouldPlay: !isPaused && !reachedEnd)
    }

    /// 换源进行中，进度上报和界面快照用目标时间，不用新片段还没跳过去时的 0 秒。
    static func reportedTime(handoffTarget: Double?, playerTime: Double) -> Double {
        handoffTarget ?? playerTime
    }

    /// 已经有播放器、地址确实变了，才在同一个播放器里换片段；第一次载入走原来的载入流程。
    static func shouldHandOff(currentURL: URL?, newURL: URL, hasPlayer: Bool) -> Bool {
        hasPlayer && currentURL != nil && currentURL != newURL
    }
}

enum PlaybackVolumePreference {
    private static let key = "playbackVolume"

    static func normalized(_ volume: Double) -> Double {
        guard volume.isFinite else { return 1 }
        return min(1, max(0, volume))
    }

    static func load(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil else { return 1 }
        return normalized(defaults.double(forKey: key))
    }

    static func save(_ volume: Double, to defaults: UserDefaults = .standard) {
        defaults.set(normalized(volume), forKey: key)
    }
}

enum PictureInPicturePolicy {
    static func shouldStart(
        isPrimarySurfaceVisible: Bool,
        isPlaying: Bool,
        reachedEnd: Bool,
        isAlreadyActive: Bool,
        isExternalPlaybackActive: Bool
    ) -> Bool {
        !isPrimarySurfaceVisible
            && isPlaying
            && !reachedEnd
            && !isAlreadyActive
            && !isExternalPlaybackActive
    }
}

enum FloatingPlayerLayout {
    static let size = NSSize(width: 420, height: 236.25)
    static let margin: CGFloat = 24

    static func frame(in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.maxX - size.width - margin,
            y: visibleFrame.minY + margin,
            width: size.width,
            height: size.height
        )
    }
}

final class PlaybackCommandCenter {
    static let shared = PlaybackCommandCenter()

    private var activeToken: UUID?
    private weak var routePlayer: AVPlayer?
    private var skipHandler: ((Double) -> Void)?
    private var toggleHandler: (() -> Void)?
    private var setPlayingHandler: ((Bool) -> Void)?
    private var muteHandler: (() -> Void)?
    private var rateHandler: ((Double) -> Void)?
    private var rateSelectionHandler: ((Double) -> Void)?
    private var fullscreenHandler: (() -> Bool)?
    private var fullscreenExitHandler: (() -> Bool)?

    var hasActivePlayer: Bool { activeToken != nil }
    var activeRoutePlayer: AVPlayer? { routePlayer }

    func isActive(_ token: UUID?) -> Bool {
        guard let token else { return false }
        return activeToken == token
    }

    private init() {}

    func register(
        player: AVPlayer? = nil,
        skip: @escaping (Double) -> Void,
        toggle: @escaping () -> Void,
        setPlaying: @escaping (Bool) -> Void,
        mute: @escaping () -> Void,
        adjustRate: @escaping (Double) -> Void,
        setRate: @escaping (Double) -> Void,
        toggleFullscreen: @escaping () -> Bool,
        exitFullscreen: @escaping () -> Bool
    ) -> UUID {
        let token = UUID()
        activeToken = token
        routePlayer = player
        skipHandler = skip
        toggleHandler = toggle
        setPlayingHandler = setPlaying
        muteHandler = mute
        rateHandler = adjustRate
        rateSelectionHandler = setRate
        fullscreenHandler = toggleFullscreen
        fullscreenExitHandler = exitFullscreen
        return token
    }

    func unregister(_ token: UUID) {
        guard token == activeToken else { return }
        activeToken = nil
        routePlayer = nil
        skipHandler = nil
        toggleHandler = nil
        setPlayingHandler = nil
        muteHandler = nil
        rateHandler = nil
        rateSelectionHandler = nil
        fullscreenHandler = nil
        fullscreenExitHandler = nil
    }

    @discardableResult
    func skip(by seconds: Double) -> Bool {
        guard let skipHandler else { return false }
        skipHandler(seconds)
        return true
    }

    @discardableResult
    func togglePlayback() -> Bool {
        guard let toggleHandler else { return false }
        toggleHandler()
        return true
    }

    @discardableResult
    func play() -> Bool {
        guard let setPlayingHandler else { return false }
        setPlayingHandler(true)
        return true
    }

    @discardableResult
    func pause() -> Bool {
        guard let setPlayingHandler else { return false }
        setPlayingHandler(false)
        return true
    }

    @discardableResult
    func toggleMute() -> Bool {
        guard let muteHandler else { return false }
        muteHandler()
        return true
    }

    @discardableResult
    func adjustPlaybackRate(by amount: Double) -> Bool {
        guard let rateHandler else { return false }
        rateHandler(amount)
        return true
    }

    @discardableResult
    func setPlaybackRate(to rate: Double) -> Bool {
        guard let rateSelectionHandler else { return false }
        rateSelectionHandler(PlaybackRatePolicy.normalized(rate))
        return true
    }

    @discardableResult
    func toggleFullscreen() -> Bool {
        fullscreenHandler?() ?? false
    }

    @discardableResult
    func exitFullscreen() -> Bool {
        fullscreenExitHandler?() ?? false
    }
}

struct AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
        picker.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        picker.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        picker.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
        picker.player = PlaybackCommandCenter.shared.activeRoutePlayer
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        if picker.player !== PlaybackCommandCenter.shared.activeRoutePlayer {
            picker.player = PlaybackCommandCenter.shared.activeRoutePlayer
        }
    }
}

struct LocalVideoPlayer: NSViewRepresentable {
    let url: URL
    let title: String
    /// 主标题下面那行原标题，只在小窗里显示。主标题就是原标题时为 nil。
    let originalTitle: String?
    let author: String
    let resumeAt: Double
    let seekRequest: PlayerSeekRequest?
    let subtitleTrack: VideoSubtitleTrack?
    let subtitleMode: SubtitleDisplayMode
    let sourceURLString: String
    let skipSponsorsEnabled: Bool
    let onProgress: (Double) -> Void
    let onStateChange: (PlaybackSnapshot) -> Void
    let onVolumeChange: (Double) -> Void
    let onSponsorSkip: (Double) -> Void
    let onEnded: () -> Void
    /// 片段载入失败时回调；在线预览失效时由界面退回等待画面，下完再播。
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onProgress: onProgress,
            onStateChange: onStateChange,
            onVolumeChange: onVolumeChange,
            onSponsorSkip: onSponsorSkip,
            onEnded: onEnded,
            onUnavailable: onUnavailable
        )
    }

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleVideoClick(_:))
        )
        view.addGestureRecognizer(click)
        context.coordinator.updateFloatingTitle(title: title, originalTitle: originalTitle)
        context.coordinator.load(url: url, title: title, author: author, resumeAt: resumeAt, into: view)
        context.coordinator.updateSubtitles(track: subtitleTrack, mode: subtitleMode)
        context.coordinator.updateSponsorSkip(sourceURLString: sourceURLString, enabled: skipSponsorsEnabled)
        return view
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: PlayerLayerHostView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: max(0, proposal.width ?? 640),
            height: max(0, proposal.height ?? 360)
        )
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        context.coordinator.onUnavailable = onUnavailable
        context.coordinator.updateFloatingTitle(title: title, originalTitle: originalTitle)
        if context.coordinator.currentURL != url {
            if context.coordinator.canHandOff(to: url) {
                // 同一条视频的片源变了（在线预览下完换成本地文件）：不重建播放器，原地换片段。
                context.coordinator.handOff(to: url)
            } else {
                context.coordinator.load(url: url, title: title, author: author, resumeAt: resumeAt, into: view)
                context.coordinator.updateSubtitles(track: subtitleTrack, mode: subtitleMode)
                context.coordinator.updateSponsorSkip(sourceURLString: sourceURLString, enabled: skipSponsorsEnabled)
                return
            }
        }
        context.coordinator.updateMetadata(title: title, author: author)
        context.coordinator.updateSubtitles(track: subtitleTrack, mode: subtitleMode)
        context.coordinator.updateSponsorSkip(sourceURLString: sourceURLString, enabled: skipSponsorsEnabled)
        if let seekRequest {
            context.coordinator.seek(to: seekRequest)
        }
    }

    static func dismantleNSView(_ view: PlayerLayerHostView, coordinator: Coordinator) {
        coordinator.stop()
        view.playerLayer.player = nil
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private var player: AVPlayer?
        private weak var playerView: PlayerLayerHostView?
        private var backgroundPanel: NSPanel?
        private var backgroundPlayerView: FloatingVideoPlayerView?
        private var floatingTitle = ""
        private var floatingOriginalTitle: String?
        private weak var fullscreenWindow: NSWindow?
        private weak var fullscreenContainerView: NSView?
        private var fullscreenPlayerView: PlayerLayerHostView?
        private var fullscreenToolbarWasVisible: Bool?
        private var fullscreenObservers: [NSObjectProtocol] = []
        private var isVideoFullscreen = false
        private var shouldExitAfterEnteringFullscreen = false
        private var applicationObservers: [NSObjectProtocol] = []
        private var backgroundOverlayDismissed = false
        private var endObserver: NSObjectProtocol?
        private var itemStatusObserver: NSKeyValueObservation?
        private var persistenceObserver: Any?
        private var stateObserver: Any?
        private var externalPlaybackObserver: NSKeyValueObservation?
        private var reachedEnd = false
        private let onProgress: (Double) -> Void
        private let onStateChange: (PlaybackSnapshot) -> Void
        private let onVolumeChange: (Double) -> Void
        private let onSponsorSkip: (Double) -> Void
        private let onEnded: () -> Void
        fileprivate var onUnavailable: () -> Void
        /// 换片段时要跳到的时间；跳转完成前，进度上报和快照都用它，不用新片段的 0 秒。
        private var handoffTarget: Double?
        /// 换片段期间播放器先暂停，快照照旧报「在播」，播放按钮不闪。
        private var handoffResumesPlayback = false
        /// 换片段那次跳转的编号，用来分辨它和用户自己发起的跳转。
        private var handoffSeekID: UInt64?
        /// 续播跳转还没完成时的目标时间，换片段时用得上。
        private var pendingResumeTime: Double?
        private var lastSeekRequestID: UUID?
        private var sourceURLString = ""
        private var skipEnabled = true
        private var skipSession = SponsorSkipSession()
        private var skipFetchTask: URLSessionDataTask?
        private var skipFetchVideoID: String?
        private var resumeSeekPending = false
        private var seekSession = SubtitleSeekSession()
        private var commandToken: UUID?
        private var preferredRate: Double = 1
        private var currentTitle = ""
        private var currentAuthor = ""
        private var subtitleTrack: VideoSubtitleTrack?
        private var subtitleDisplayMode: SubtitleDisplayMode = .off
        fileprivate var currentURL: URL?

        init(
            onProgress: @escaping (Double) -> Void,
            onStateChange: @escaping (PlaybackSnapshot) -> Void,
            onVolumeChange: @escaping (Double) -> Void,
            onSponsorSkip: @escaping (Double) -> Void,
            onEnded: @escaping () -> Void,
            onUnavailable: @escaping () -> Void
        ) {
            self.onProgress = onProgress
            self.onStateChange = onStateChange
            self.onVolumeChange = onVolumeChange
            self.onSponsorSkip = onSponsorSkip
            self.onEnded = onEnded
            self.onUnavailable = onUnavailable
            super.init()
        }

        func load(
            url: URL,
            title: String,
            author: String,
            resumeAt: Double,
            into view: PlayerLayerHostView
        ) {
            stop()
            currentURL = url
            currentTitle = title
            currentAuthor = author
            reachedEnd = false
            lastSeekRequestID = nil
            seekSession.invalidate()
            preferredRate = PlaybackRatePreference.load()
            let playerItem = AVPlayerItem(url: url)
            let player = PlaybackAudioPolicy.makePlayer(playing: playerItem)
            player.volume = Float(PlaybackVolumePreference.load())
            self.player = player
            playerView = view
            view.playerLayer.player = player
            view.onVolumeScroll = { [weak self] adjustment in
                self?.adjustVolume(by: adjustment)
            }
            backgroundOverlayDismissed = false
            observeApplicationActivation()
            commandToken = PlaybackCommandCenter.shared.register(
                player: player,
                skip: { [weak self] seconds in self?.skip(by: seconds) },
                toggle: { [weak self] in self?.togglePlayback() },
                setPlaying: { [weak self] shouldPlay in self?.setPlayback(shouldPlay) },
                mute: { [weak self] in self?.toggleMute() },
                adjustRate: { [weak self] amount in self?.adjustPlaybackRate(by: amount) },
                setRate: { [weak self] rate in self?.setPlaybackRate(rate) },
                toggleFullscreen: { [weak self] in self?.toggleFullscreen() ?? false },
                exitFullscreen: { [weak self] in self?.exitFullscreen() ?? false }
            )
            SystemMediaController.shared.activate(player: player)
            SystemMediaController.shared.setItem(title: title, author: author)
            externalPlaybackObserver = player.observe(
                \.isExternalPlaybackActive,
                options: [.initial, .new]
            ) { [weak self] player, _ in
                DispatchQueue.main.async {
                    self?.externalPlaybackChanged(isActive: player.isExternalPlaybackActive)
                }
            }
            persistenceObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 2, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                guard let self, self.canReportProgress else { return }
                let seconds = PlaybackHandoffPolicy.reportedTime(
                    handoffTarget: self.handoffTarget,
                    playerTime: time.seconds
                )
                guard seconds.isFinite else { return }
                self.onProgress(seconds)
            }
            stateObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                guard let self else { return }
                self.publishSnapshot()
                self.publishSubtitle(at: self.subtitleClockTime(playerTime: time.seconds), animated: true)
                self.considerSponsorSkip(at: time.seconds)
            }
            observeItemEnd(of: playerItem)
            observeItemStatus(of: playerItem)
            if resumeAt > 0 {
                resumeSeekPending = true
                pendingResumeTime = resumeAt
                let time = CMTime(seconds: resumeAt, preferredTimescale: 600)
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self else { return }
                    self.resumeSeekPending = false
                    self.pendingResumeTime = nil
                    self.publishSnapshot()
                    self.considerSponsorSkip(at: resumeAt)
                }
            } else {
                publishSnapshot()
            }
        }

        func canHandOff(to url: URL) -> Bool {
            PlaybackHandoffPolicy.shouldHandOff(currentURL: currentURL, newURL: url, hasPlayer: player != nil)
        }

        /// 在线预览下完换成本地文件：不重建播放器，原地换片段，零容差跳回原来的时间，原来在播就接着播。
        /// 全屏视图、悬浮小窗、媒体键登记、音量和倍速都挂在同一个 AVPlayer 上，换片段不影响它们。
        func handOff(to url: URL) {
            guard let player else { return }
            let previousURL = currentURL
            let plan = PlaybackHandoffPolicy.plan(
                playerTime: player.currentTime().seconds,
                pendingSeekTime: seekSession.pendingTime,
                pendingResumeTime: resumeSeekPending ? pendingResumeTime : nil,
                isPaused: player.timeControlStatus == .paused,
                reachedEnd: reachedEnd
            )
            handoffTarget = plan.time
            handoffResumesPlayback = plan.shouldPlay
            // 先把换源时的位置存下来：新片段万一载入失败，续播位置也不会丢。
            // 这里在界面更新过程中，存位置会改队列，所以放到下一轮再做。
            DispatchQueue.main.async { [onProgress] in onProgress(plan.time) }
            player.pause()
            let playerItem = AVPlayerItem(url: url)
            playerItem.audioTimePitchAlgorithm = PlaybackAudioPolicy.timePitchAlgorithm
            player.replaceCurrentItem(with: playerItem)
            currentURL = url
            // 播完通知和片段状态观察跟着片段走，要改绑到新片段；其余观察挂在播放器上，不用动。
            observeItemEnd(of: playerItem)
            observeItemStatus(of: playerItem)
            os_log(
                "handoff begins from=%{public}@ to=%{public}@ at=%.3f play=%{public}@",
                log: playbackHandoffLog,
                type: .default,
                previousURL.map(Self.sourceDescription) ?? "none",
                Self.sourceDescription(url),
                plan.time,
                plan.shouldPlay ? "yes" : "no"
            )
            // 跳转落地后再按当时的状态决定开不开播：换片段期间用户按了暂停，就不开播。
            handoffSeekID = beginSeek(player: player, to: plan.time, shouldPlay: false) { [weak self] landedTime in
                guard let self else { return }
                let resumes = self.handoffResumesPlayback
                self.clearHandoff()
                if resumes { self.startPlayback(player) }
                self.publishSnapshot()
                os_log(
                    "handoff landed at=%.3f target=%.3f play=%{public}@",
                    log: playbackHandoffLog,
                    type: .default,
                    landedTime,
                    plan.time,
                    resumes ? "yes" : "no"
                )
            }
        }

        private func clearHandoff() {
            handoffTarget = nil
            handoffResumesPlayback = false
            handoffSeekID = nil
        }

        /// 换片段期间播放器先暂停；对外仍按换片段前的状态算「在不在播」。
        private var isEffectivelyPlaying: Bool {
            if handoffTarget != nil { return handoffResumesPlayback }
            return player.map { $0.timeControlStatus != .paused } ?? false
        }

        /// 片段载入失败后，播放器时间是 0 或无效，不能拿来覆盖已保存的续播位置。
        private var canReportProgress: Bool {
            player?.currentItem?.status != .failed
        }

        /// 日志只记格式或文件名，不记带签名的完整在线地址。
        private static func sourceDescription(_ url: URL) -> String {
            if url.isFileURL { return "file:\(url.lastPathComponent)" }
            let itag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "itag" }?.value
            return itag.map { "stream itag \($0)" } ?? "stream \(url.host ?? "unknown")"
        }

        private func observeItemEnd(of playerItem: AVPlayerItem) {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                self?.reachedEnd = true
                self?.publishSnapshot()
                self?.onEnded()
            }
        }

        /// 片段载入失败（例如在线预览地址失效）时告诉界面，界面退回等待画面、下完再播。
        private func observeItemStatus(of playerItem: AVPlayerItem) {
            itemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                DispatchQueue.main.async { self?.onUnavailable() }
            }
        }

        /// 小窗悬停时左上角显示的标题。
        func updateFloatingTitle(title: String, originalTitle: String?) {
            guard title != floatingTitle || originalTitle != floatingOriginalTitle else { return }
            floatingTitle = title
            floatingOriginalTitle = originalTitle
            backgroundPlayerView?.setTitle(title, originalTitle: originalTitle)
        }

        func updateMetadata(title: String, author: String) {
            guard title != currentTitle || author != currentAuthor else { return }
            currentTitle = title
            currentAuthor = author
            if PlaybackCommandCenter.shared.isActive(commandToken) {
                SystemMediaController.shared.setItem(title: title, author: author)
            }
        }

        func updateSubtitles(track: VideoSubtitleTrack?, mode: SubtitleDisplayMode) {
            subtitleTrack = track
            subtitleDisplayMode = mode
            publishSubtitle(at: subtitleClockTime(playerTime: player?.currentTime().seconds ?? 0), animated: false)
        }

        func seek(to request: PlayerSeekRequest) {
            guard lastSeekRequestID != request.id, let player else { return }
            lastSeekRequestID = request.id
            reachedEnd = false
            beginSeek(
                player: player,
                to: SubtitleDispatchPolicy.presentationTime(
                    afterSeekTo: request.time,
                    playerTime: player.currentTime().seconds
                ),
                shouldPlay: request.shouldPlay
            )
        }

        private func skip(by seconds: Double) {
            guard let player else { return }
            let current = PlaybackHandoffPolicy.reportedTime(
                handoffTarget: handoffTarget,
                playerTime: player.currentTime().seconds
            )
            guard current.isFinite else { return }
            var target = max(0, current + seconds)
            let duration = player.currentItem?.duration.seconds ?? .nan
            if duration.isFinite { target = min(target, duration) }
            let shouldKeepPlaying = isEffectivelyPlaying
            reachedEnd = false
            let seekTime = SubtitleDispatchPolicy.presentationTime(
                afterSeekTo: target,
                playerTime: current
            )
            beginSeek(player: player, to: seekTime, shouldPlay: shouldKeepPlaying)
            onProgress(seekTime)
        }

        @discardableResult
        private func beginSeek(
            player: AVPlayer,
            to seekTime: Double,
            shouldPlay: Bool,
            onLanded: ((Double) -> Void)? = nil
        ) -> UInt64 {
            let requestID = seekSession.issue(time: seekTime)
            publishSubtitle(at: seekTime, animated: false)
            let time = CMTime(
                value: SubtitleDispatchPolicy.quantizedSeekTicks(seekTime),
                timescale: SubtitleDispatchPolicy.seekTimescale
            )
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self else { return }
                let isLatest = requestID == self.seekSession.latestID
                if isLatest, let handoffSeekID = self.handoffSeekID, handoffSeekID != requestID {
                    // 换片段期间用户自己拖了进度：以用户的为准，结束换片段状态。
                    self.clearHandoff()
                }
                guard self.seekSession.complete(id: requestID, finished: finished) != nil else {
                    // 换片段的跳转没跳成（片段载入失败），不再一直报目标时间。
                    if isLatest, requestID == self.handoffSeekID { self.clearHandoff() }
                    return
                }
                if shouldPlay { self.startPlayback(player) }
                self.publishSnapshot()
                self.publishSubtitle(at: seekTime, animated: false)
                self.considerSponsorSkip(at: seekTime)
                onLanded?(player.currentTime().seconds)
            }
            return requestID
        }

        func updateSponsorSkip(sourceURLString: String, enabled: Bool) {
            let sourceChanged = self.sourceURLString != sourceURLString
            let enabledChanged = skipEnabled != enabled
            self.sourceURLString = sourceURLString
            skipEnabled = enabled
            if sourceChanged {
                skipSession.reset()
                skipFetchVideoID = nil
                refreshSkipSegments()
                return
            }
            if enabledChanged, enabled {
                if skipSession.segments.isEmpty {
                    refreshSkipSegments()
                } else if let time = player?.currentTime().seconds {
                    considerSponsorSkip(at: time)
                }
            }
        }

        private func refreshSkipSegments() {
            skipFetchTask?.cancel()
            skipFetchTask = nil
            guard skipEnabled else { return }
            guard let videoID = YouTubeVideoID.extract(from: sourceURLString) else { return }
            if skipFetchVideoID == videoID, !skipSession.segments.isEmpty { return }
            skipFetchVideoID = videoID
            skipFetchTask = SponsorBlockClient.fetch(videoID: videoID) { [weak self] segments in
                guard let self, self.skipFetchVideoID == videoID else { return }
                self.skipSession.replaceSegments(segments)
                if let time = self.player?.currentTime().seconds {
                    self.considerSponsorSkip(at: time)
                }
            }
        }

        private func considerSponsorSkip(at time: Double) {
            guard skipEnabled, !resumeSeekPending, seekSession.pendingTime == nil, player != nil else { return }
            guard let decision = skipSession.consumeSkip(at: time), let player else { return }
            let shouldPlay = player.timeControlStatus != .paused
            reachedEnd = false
            beginSeek(player: player, to: decision.end, shouldPlay: shouldPlay)
            onProgress(decision.end)
            onSponsorSkip(decision.skippedDuration)
        }

        private func togglePlayback() {
            guard player != nil else { return }
            setPlayback(!isEffectivelyPlaying)
        }

        private func setPlayback(_ shouldPlay: Bool) {
            guard let player else { return }
            if handoffTarget != nil {
                // 换片段还没落地：只记下用户的意思，落地后照办。
                handoffResumesPlayback = shouldPlay
                if !shouldPlay, let handoffTarget { onProgress(handoffTarget) }
            } else if !shouldPlay {
                player.pause()
                let seconds = player.currentTime().seconds
                if seconds.isFinite, canReportProgress { onProgress(seconds) }
            } else if player.timeControlStatus == .paused {
                if reachedEnd {
                    reachedEnd = false
                    player.seek(to: .zero)
                }
                startPlayback(player)
            }
            publishSnapshot()
        }

        private func toggleMute() {
            guard let player else { return }
            player.isMuted.toggle()
            publishSnapshot()
            onVolumeChange(player.isMuted ? 0 : Double(player.volume))
        }

        private func adjustVolume(by amount: Double) {
            guard let player else { return }
            let volume = PlaybackVolumePreference.normalized(Double(player.volume) + amount)
            player.volume = Float(volume)
            if volume > 0, player.isMuted { player.isMuted = false }
            PlaybackVolumePreference.save(volume)
            publishSnapshot()
            onVolumeChange(volume)
        }

        private func adjustPlaybackRate(by amount: Double) {
            setPlaybackRate(PlaybackRatePolicy.adjusted(preferredRate, by: amount))
        }

        private func setPlaybackRate(_ rate: Double) {
            preferredRate = PlaybackRatePolicy.normalized(rate)
            PlaybackRatePreference.save(preferredRate)
            if let player {
                let shouldKeepPlaying = player.timeControlStatus != .paused
                if shouldKeepPlaying {
                    // `rate` is AVFoundation's instantaneous clock adjustment.
                    // Do not call play, pause, seek, or preroll here: each can
                    // restart part of the media pipeline and create an audio gap.
                    player.rate = Float(preferredRate)
                }
            }
            publishSnapshot()
        }

        private func startPlayback(_ player: AVPlayer) {
            player.playImmediately(atRate: Float(preferredRate))
        }

        private func toggleFullscreen() -> Bool {
            if isVideoFullscreen {
                return exitFullscreen()
            }
            guard let window = playerView?.window,
                  beginFullscreenPresentation(in: window) else { return false }

            // If the user already put the window in a native full-screen
            // Space with the green button, F only switches to video-only
            // presentation. Otherwise use NSWindow's native transition so
            // Mission Control and trackpad Space switching work normally.
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            return true
        }

        private func exitFullscreen() -> Bool {
            guard let window = fullscreenWindow ?? playerView?.window else { return false }

            if isVideoFullscreen {
                if window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                } else {
                    // The native transition has not reached didEnter yet.
                    // Finish entering, then immediately request the matching
                    // native exit rather than stranding the app in that Space.
                    shouldExitAfterEnteringFullscreen = true
                }
                return true
            }

            guard window.styleMask.contains(.fullScreen) else { return false }
            window.toggleFullScreen(nil)
            return true
        }

        private func beginFullscreenPresentation(in window: NSWindow) -> Bool {
            guard let player,
                  let contentView = window.contentView,
                  let containerView = contentView.superview else { return false }

            hideBackgroundPlayer(animated: false, restoreInline: true)
            fullscreenToolbarWasVisible = window.toolbar?.isVisible
            window.toolbar?.isVisible = false

            // Install above the window's frame view, not inside SwiftUI's
            // hosting view. NavigationSplitView can reorder hosting subviews
            // during the native full-screen transition, which would otherwise
            // put this surface behind the sidebar and detail content.
            let fullscreenView = PlayerLayerHostView(frame: containerView.bounds)
            fullscreenView.translatesAutoresizingMaskIntoConstraints = false
            fullscreenView.wantsLayer = true
            fullscreenView.layer?.backgroundColor = NSColor.black.cgColor
            fullscreenView.playerLayer.videoGravity = .resizeAspect
            fullscreenView.onVolumeScroll = { [weak self] adjustment in
                self?.adjustVolume(by: adjustment)
            }
            fullscreenView.addGestureRecognizer(NSClickGestureRecognizer(
                target: self,
                action: #selector(handleVideoClick(_:))
            ))

            playerView?.playerLayer.player = nil
            fullscreenView.playerLayer.player = player
            containerView.addSubview(fullscreenView, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                fullscreenView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                fullscreenView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                fullscreenView.topAnchor.constraint(equalTo: containerView.topAnchor),
                fullscreenView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])

            fullscreenWindow = window
            fullscreenContainerView = containerView
            fullscreenPlayerView = fullscreenView
            isVideoFullscreen = true
            shouldExitAfterEnteringFullscreen = false
            observeFullscreenTransitions(for: window)
            publishCurrentSubtitle(animated: false)
            return true
        }

        private func observeFullscreenTransitions(for window: NSWindow) {
            removeFullscreenObservers()
            let center = NotificationCenter.default
            fullscreenObservers = [
                center.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    guard let self, let window,
                          self.isVideoFullscreen,
                          self.shouldExitAfterEnteringFullscreen else { return }
                    self.shouldExitAfterEnteringFullscreen = false
                    window.toggleFullScreen(nil)
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.finishFullscreenPresentation(restoreInline: true)
                },
            ]
        }

        private func finishFullscreenPresentation(restoreInline: Bool) {
            let window = fullscreenWindow
            fullscreenPlayerView?.playerLayer.player = nil
            fullscreenPlayerView?.onVolumeScroll = nil
            fullscreenPlayerView?.removeFromSuperview()
            fullscreenPlayerView = nil
            fullscreenContainerView = nil
            if let fullscreenToolbarWasVisible {
                window?.toolbar?.isVisible = fullscreenToolbarWasVisible
            }
            self.fullscreenToolbarWasVisible = nil
            fullscreenWindow = nil
            isVideoFullscreen = false
            shouldExitAfterEnteringFullscreen = false
            removeFullscreenObservers()

            if restoreInline, backgroundPanel == nil, let player {
                playerView?.playerLayer.player = player
            }
            if restoreInline {
                publishCurrentSubtitle(animated: false)
            }
        }

        private func removeFullscreenObservers() {
            for observer in fullscreenObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            fullscreenObservers.removeAll()
        }

        private func observeApplicationActivation() {
            applicationObservers = [
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: NSApp,
                    queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self?.showBackgroundPlayerIfAppropriate()
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: NSApp,
                    queue: .main
                ) { [weak self] _ in
                    guard self?.playerView?.window?.isMiniaturized != true else {
                        self?.showBackgroundPlayerIfAppropriate()
                        return
                    }
                    self?.backgroundOverlayDismissed = false
                    self?.hideBackgroundPlayer(animated: true, restoreInline: true)
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMiniaturizeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    guard let self,
                          notification.object as? NSWindow === self.playerView?.window else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.showBackgroundPlayerIfAppropriate()
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    guard let self,
                          notification.object as? NSWindow === self.playerView?.window,
                          NSApp.isActive else { return }
                    self.backgroundOverlayDismissed = false
                    self.hideBackgroundPlayer(animated: true, restoreInline: true)
                }
            ]
        }

        private func externalPlaybackChanged(isActive: Bool) {
            if isActive {
                hideBackgroundPlayer(animated: true, restoreInline: true)
            } else if !NSApp.isActive {
                showBackgroundPlayerIfAppropriate()
            }
            publishSnapshot()
        }

        private func showBackgroundPlayerIfAppropriate() {
            guard let player,
                  !backgroundOverlayDismissed,
                  PictureInPicturePolicy.shouldStart(
                    isPrimarySurfaceVisible: NSApp.isActive
                        && playerView?.window?.isMiniaturized != true,
                    isPlaying: player.timeControlStatus != .paused,
                    reachedEnd: reachedEnd,
                    isAlreadyActive: backgroundPanel != nil,
                    isExternalPlaybackActive: player.isExternalPlaybackActive
                  ) else { return }

            let floatingView = FloatingVideoPlayerView()
            floatingView.onVolumeScroll = { [weak self] adjustment in
                self?.adjustVolume(by: adjustment)
            }
            floatingView.controlsStyle = .floating
            floatingView.videoGravity = .resizeAspect
            floatingView.showsFullScreenToggleButton = false
            floatingView.wantsLayer = true
            floatingView.layer?.cornerRadius = 16
            floatingView.layer?.masksToBounds = true
            floatingView.setAccessibilityLabel("悬浮播放器")
            floatingView.setTitle(floatingTitle, originalTitle: floatingOriginalTitle)

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: FloatingPlayerLayout.size),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.delegate = self
            panel.title = "悬浮播放器"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.contentAspectRatio = NSSize(width: 16, height: 9)
            panel.minSize = NSSize(width: 280, height: 157.5)
            panel.backgroundColor = .black
            panel.isOpaque = false
            panel.hasShadow = true
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            panel.contentView = floatingView
            floatingView.onHoverChanged = { [weak panel] isHovering in
                panel?.standardWindowButton(.closeButton)?.isHidden = !isHovering
            }
            floatingView.onReturnToMainWindow = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.returnToMainWindow(from: panel)
            }

            let visibleFrame = playerView?.window?.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(origin: .zero, size: FloatingPlayerLayout.size)
            panel.setFrame(FloatingPlayerLayout.frame(in: visibleFrame), display: false)

            // Move the existing player output only after the panel is fully
            // configured. The panel is shown at its final location, so the sole
            // transition is opacity; there is never a position animation.
            playerView?.playerLayer.player = nil
            fullscreenPlayerView?.playerLayer.player = nil
            floatingView.player = player
            backgroundPanel = panel
            backgroundPlayerView = floatingView
            publishCurrentSubtitle(animated: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            guard duration > 0 else {
                panel.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }

        private func hideBackgroundPlayer(animated: Bool, restoreInline: Bool) {
            guard let panel = backgroundPanel else {
                if restoreInline, let player {
                    attachPlayerToPrimarySurface(player)
                }
                return
            }

            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard animated, !reduceMotion else {
                finishHidingBackgroundPlayer(panel, restoreInline: restoreInline)
                return
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak panel] in
                guard let self, let panel, self.backgroundPanel === panel else { return }
                self.finishHidingBackgroundPlayer(panel, restoreInline: restoreInline)
            })
        }

        private func finishHidingBackgroundPlayer(_ panel: NSPanel, restoreInline: Bool) {
            guard backgroundPanel === panel else { return }
            backgroundPlayerView?.player = nil
            backgroundPlayerView?.onVolumeScroll = nil
            backgroundPlayerView?.onHoverChanged = nil
            backgroundPlayerView?.onReturnToMainWindow = nil
            if restoreInline, let player {
                attachPlayerToPrimarySurface(player)
            }
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
            backgroundPlayerView = nil
            backgroundPanel = nil
            if restoreInline {
                publishCurrentSubtitle(animated: false)
            }
        }

        private func returnToMainWindow(from panel: NSPanel) {
            guard backgroundPanel === panel else { return }
            let mainWindow = NSApp.windows.first { window in
                window !== panel && !(window is NSPanel) && window.canBecomeMain
            }
            backgroundOverlayDismissed = false
            hideBackgroundPlayer(animated: false, restoreInline: true)
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
        }

        @objc func handleVideoClick(_ gesture: NSClickGestureRecognizer) {
            guard gesture.state == .ended else { return }
            togglePlayback()
        }

        func windowWillClose(_ notification: Notification) {
            guard let panel = notification.object as? NSPanel,
                  backgroundPanel === panel else { return }
            backgroundOverlayDismissed = true
            backgroundPlayerView?.player = nil
            backgroundPlayerView?.onVolumeScroll = nil
            backgroundPlayerView?.onHoverChanged = nil
            backgroundPlayerView?.onReturnToMainWindow = nil
            backgroundPlayerView = nil
            backgroundPanel = nil
            if let player {
                player.pause()
                attachPlayerToPrimarySurface(player)
                let seconds = player.currentTime().seconds
                if seconds.isFinite { onProgress(seconds) }
            }
            publishSnapshot()
            publishCurrentSubtitle(animated: false)
        }

        private func attachPlayerToPrimarySurface(_ player: AVPlayer) {
            if isVideoFullscreen, let fullscreenPlayerView {
                fullscreenPlayerView.playerLayer.player = player
            } else {
                playerView?.playerLayer.player = player
            }
        }

        private func publishSnapshot() {
            guard let player else { return }
            let rawCurrent = PlaybackHandoffPolicy.reportedTime(
                handoffTarget: handoffTarget,
                playerTime: player.currentTime().seconds
            )
            let rawDuration = player.currentItem?.duration.seconds ?? .nan
            let snapshot = PlaybackSnapshot(
                currentTime: rawCurrent.isFinite ? max(0, rawCurrent) : 0,
                duration: rawDuration.isFinite ? max(0, rawDuration) : 0,
                isPlaying: isEffectivelyPlaying,
                isMuted: player.isMuted,
                volume: Double(player.volume),
                playbackRate: preferredRate,
                isExternalPlaybackActive: player.isExternalPlaybackActive
            )
            DispatchQueue.main.async { [onStateChange] in
                onStateChange(snapshot)
            }
            if PlaybackCommandCenter.shared.isActive(commandToken) {
                SystemMediaController.shared.update(snapshot)
            }
        }

        private func subtitleClockTime(playerTime: Double) -> Double {
            SubtitleDispatchPolicy.visibleTime(
                pendingSeekTime: seekSession.pendingTime,
                playerTime: playerTime
            )
        }

        private func currentSubtitleTime() -> Double {
            subtitleClockTime(playerTime: player?.currentTime().seconds ?? .nan)
        }

        private func publishCurrentSubtitle(animated: Bool) {
            publishSubtitle(at: currentSubtitleTime(), animated: animated)
        }

        private func publishSubtitle(at time: Double, animated: Bool) {
            let presentation = VideoSubtitlePresentation.resolve(
                track: subtitleTrack,
                mode: subtitleDisplayMode,
                at: time
            )
            let destination = SubtitleDispatchPolicy.destination(
                isFloatingActive: backgroundPlayerView != nil,
                isFullscreen: isVideoFullscreen
            )
            func apply(
                _ surface: SubtitleDispatchSurface,
                set: (VideoSubtitlePresentation?, Bool) -> Void
            ) {
                let receives = SubtitleDispatchPolicy.shouldReceive(surface, destination: destination)
                set(receives ? presentation : nil, receives && animated)
            }
            apply(.primary) { playerView?.setSubtitlePresentation($0, animated: $1) }
            apply(.fullscreen) { fullscreenPlayerView?.setSubtitlePresentation($0, animated: $1) }
            apply(.floating) { backgroundPlayerView?.setSubtitlePresentation($0, animated: $1) }
        }

        func stop() {
            skipFetchTask?.cancel()
            skipFetchTask = nil
            skipFetchVideoID = nil
            skipSession.reset()
            sourceURLString = ""
            resumeSeekPending = false
            _ = exitFullscreen()
            hideBackgroundPlayer(animated: false, restoreInline: false)
            finishFullscreenPresentation(restoreInline: false)
            for observer in applicationObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            applicationObservers.removeAll()
            if let player {
                player.pause()
                if !reachedEnd, canReportProgress {
                    let seconds = PlaybackHandoffPolicy.reportedTime(
                        handoffTarget: handoffTarget,
                        playerTime: player.currentTime().seconds
                    )
                    if seconds.isFinite { onProgress(seconds) }
                }
                if let persistenceObserver {
                    player.removeTimeObserver(persistenceObserver)
                }
                if let stateObserver {
                    player.removeTimeObserver(stateObserver)
                }
                let rawCurrent = player.currentTime().seconds
                let rawDuration = player.currentItem?.duration.seconds ?? .nan
                if PlaybackCommandCenter.shared.isActive(commandToken) {
                    SystemMediaController.shared.update(PlaybackSnapshot(
                        currentTime: rawCurrent.isFinite ? max(0, rawCurrent) : 0,
                        duration: rawDuration.isFinite ? max(0, rawDuration) : 0,
                        isPlaying: false,
                        isMuted: player.isMuted,
                        volume: Double(player.volume),
                        playbackRate: preferredRate,
                        isExternalPlaybackActive: player.isExternalPlaybackActive
                    ))
                }
                SystemMediaController.shared.deactivate(player: player)
            }
            persistenceObserver = nil
            stateObserver = nil
            externalPlaybackObserver = nil
            player = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
            if let commandToken {
                PlaybackCommandCenter.shared.unregister(commandToken)
            }
            commandToken = nil
            seekSession.invalidate()
            playerView?.setSubtitlePresentation(nil, animated: false)
            playerView?.playerLayer.player = nil
            playerView?.onVolumeScroll = nil
            playerView = nil
            currentURL = nil
            currentTitle = ""
            currentAuthor = ""
            subtitleTrack = nil
            subtitleDisplayMode = .off
            itemStatusObserver = nil
            pendingResumeTime = nil
            clearHandoff()
        }

        deinit {
            if let player, let persistenceObserver {
                player.removeTimeObserver(persistenceObserver)
            }
            if let player, let stateObserver {
                player.removeTimeObserver(stateObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            if let commandToken {
                PlaybackCommandCenter.shared.unregister(commandToken)
            }
            for observer in applicationObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            removeFullscreenObservers()
        }
    }
}
