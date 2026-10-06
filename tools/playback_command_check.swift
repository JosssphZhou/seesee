import AppKit
import Foundation
import AVFoundation
import MediaPlayer

@main
struct PlaybackCommandCheck {
    static func main() {
        let resizingPlayerView = PlayerLayerHostView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        resizingPlayerView.setFrameSize(NSSize(width: 1_280, height: 720))
        precondition(resizingPlayerView.playerLayer.frame == resizingPlayerView.bounds)
        precondition(resizingPlayerView.playerLayer.autoresizingMask.contains(.layerWidthSizable))
        precondition(resizingPlayerView.playerLayer.autoresizingMask.contains(.layerHeightSizable))
        precondition(resizingPlayerView.playerLayer.actions?["bounds"] is NSNull)
        precondition(resizingPlayerView.playerLayer.actions?["position"] is NSNull)

        let subtitleTrack = VideoSubtitleTrack(cues: [
            VideoSubtitleCue(startTime: 0, endTime: 2, text: "Original line\n中文字幕"),
            VideoSubtitleCue(startTime: 2, endTime: 4, text: "Next line\n下一句")
        ])
        let firstSubtitle = VideoSubtitlePresentation.resolve(
            track: subtitleTrack,
            isEnabled: true,
            at: 1
        )
        let secondSubtitle = VideoSubtitlePresentation.resolve(
            track: subtitleTrack,
            isEnabled: true,
            at: 3
        )
        precondition(firstSubtitle?.text == "Original line\n中文字幕")
        precondition(firstSubtitle?.id != secondSubtitle?.id)
        precondition(VideoSubtitlePresentation.resolve(track: subtitleTrack, isEnabled: false, at: 1) == nil)

        resizingPlayerView.setSubtitlePresentation(firstSubtitle, animated: false)
        precondition(resizingPlayerView.displayedSubtitleText == "Original line\n中文字幕")
        precondition(resizingPlayerView.displayedSubtitleLines == ["Original line", "中文字幕"])
        precondition(abs(resizingPlayerView.subtitleOverlayAlpha - 1) < 0.01)
        resizingPlayerView.setSubtitlePresentation(secondSubtitle, animated: true)
        precondition(
            abs(resizingPlayerView.subtitleOverlayAlpha - 1) < 0.01,
            "句间换字不得把浮层透明度归零，实际 \(resizingPlayerView.subtitleOverlayAlpha)"
        )
        precondition(resizingPlayerView.displayedSubtitleText == "Next line\n下一句")
        resizingPlayerView.setSubtitlePresentation(firstSubtitle, animated: false)

        let floatingPlayerView = FloatingVideoPlayerView(frame: NSRect(x: 0, y: 0, width: 420, height: 236.25))
        floatingPlayerView.setSubtitlePresentation(firstSubtitle, animated: false)
        precondition(
            floatingPlayerView.displayedSubtitleText == resizingPlayerView.displayedSubtitleText,
            "主播放器与右下角悬浮窗口必须使用同一字幕视图"
        )
        precondition(
            floatingPlayerView.displayedSubtitleLines == ["Original line", "中文字幕"],
            "原文和中文字幕必须各占一行"
        )
        floatingPlayerView.setSubtitlePresentation(secondSubtitle, animated: true)
        precondition(
            abs(floatingPlayerView.subtitleOverlayAlpha - 1) < 0.01,
            "悬浮窗句间换字也不得把浮层透明度归零"
        )
        precondition(floatingPlayerView.displayedSubtitleText == "Next line\n下一句")
        let denseTrack = VideoSubtitleTrack(cues: (0..<8).map { index in
            VideoSubtitleCue(
                startTime: Double(index),
                endTime: Double(index) + 0.9,
                text: "Line \(index)\n第\(index)句"
            )
        })
        for index in 0..<8 {
            let cue = VideoSubtitlePresentation.resolve(
                track: denseTrack,
                isEnabled: true,
                at: Double(index) + 0.1
            )
            resizingPlayerView.setSubtitlePresentation(cue, animated: true)
            precondition(
                abs(resizingPlayerView.subtitleOverlayAlpha - 1) < 0.01,
                "密集换句第 \(index) 次浮层透明度被归零"
            )
        }
        let identicalSubtitle = VideoSubtitlePresentation.resolve(
            track: VideoSubtitleTrack(cues: [
                VideoSubtitleCue(startTime: 0, endTime: 2, text: "Sundar Pichai\nSundar Pichai")
            ]),
            isEnabled: true,
            at: 1
        )
        resizingPlayerView.setSubtitlePresentation(identicalSubtitle, animated: false)
        floatingPlayerView.setSubtitlePresentation(identicalSubtitle, animated: false)
        precondition(
            resizingPlayerView.displayedSubtitleLines == ["Sundar Pichai"],
            "原文与译文相同时主窗与悬浮窗都只显示一行"
        )
        precondition(floatingPlayerView.displayedSubtitleLines == ["Sundar Pichai"])
        floatingPlayerView.setSubtitlePresentation(nil, animated: false)
        precondition(floatingPlayerView.displayedSubtitleText == nil)

        let longFloatingCue = VideoSubtitleCue(
            startTime: 0,
            endTime: 2,
            text: "I've heard this before and I want the whole sentence visible.\n我听过这句话，希望整句都完整显示在小窗里。"
        )
        let longFloatingSubtitle = VideoSubtitlePresentation.resolve(
            track: VideoSubtitleTrack(cues: [longFloatingCue]),
            isEnabled: true,
            at: 1
        )
        let compactFloatingView = FloatingVideoPlayerView()
        let floatingHost = NSWindow(
            contentRect: NSRect(origin: .zero, size: FloatingPlayerLayout.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        floatingHost.contentView = compactFloatingView
        compactFloatingView.setSubtitlePresentation(longFloatingSubtitle, animated: false)
        let expectedFloatingFont = SubtitleOverlayLayout.baseFontSize(
            forSurfaceWidth: FloatingPlayerLayout.size.width
        )
        let floatingFields = subtitleTextFields(in: compactFloatingView)
        precondition(!floatingFields.isEmpty, "小窗必须画出字幕文字")
        for field in floatingFields {
            precondition(
                (field.font?.pointSize ?? 0) <= expectedFloatingFont + 0.5,
                "小窗字幕不得按主窗口字号排布，期望 ≤\(expectedFloatingFont)，实际 \(field.font?.pointSize ?? 0) 文案 \(field.stringValue)"
            )
        }
        compactFloatingView.layoutSubtreeIfNeeded()
        let laidOutFields = subtitleTextFields(in: compactFloatingView)
        for field in laidOutFields {
            precondition(
                (field.font?.pointSize ?? 0) <= expectedFloatingFont + 0.5,
                "layout 后小窗字幕仍超宽字号，期望 ≤\(expectedFloatingFont)，实际 \(field.font?.pointSize ?? 0)"
            )
            let frameInPlayer = field.convert(field.bounds, to: compactFloatingView)
            precondition(
                frameInPlayer.maxX <= compactFloatingView.bounds.width + 0.5,
                "字幕右缘超出小窗，frame=\(frameInPlayer) 窗宽=\(compactFloatingView.bounds.width)"
            )
            precondition(
                frameInPlayer.minX >= -0.5,
                "字幕左缘超出小窗，frame=\(frameInPlayer)"
            )
        }
        floatingHost.close()
        let overlayWidth = SubtitleOverlayLayout.resolve(
            lines: compactFloatingView.displayedSubtitleLines,
            surfaceWidth: FloatingPlayerLayout.size.width
        ).overlayWidth
        precondition(
            overlayWidth <= FloatingPlayerLayout.size.width,
            "小窗字幕浮层宽度必须落入窗内，实际 \(overlayWidth)"
        )

        let restoredMainView = PlayerLayerHostView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 450)
        )
        restoredMainView.setSubtitlePresentation(longFloatingSubtitle, animated: false)
        restoredMainView.layoutSubtreeIfNeeded()
        let mainFields = subtitleTextFields(in: restoredMainView)
        let expectedMainFont = SubtitleOverlayLayout.baseFontSize(forSurfaceWidth: 800)
        precondition(!mainFields.isEmpty)
        for field in mainFields {
            precondition(
                abs((field.font?.pointSize ?? 0) - expectedMainFont) < 0.5
                    || (field.font?.pointSize ?? 0) < expectedMainFont,
                "回到主窗口后字幕应恢复窗口字号，期望 \(expectedMainFont)，实际 \(field.font?.pointSize ?? 0)"
            )
        }

        precondition(PlaybackRatePolicy.adjusted(1, by: -0.1) == 1)
        precondition(PlaybackRatePolicy.adjusted(1, by: 0.1) == 1.1)
        precondition(PlaybackRatePolicy.adjusted(2.4, by: 0.1) == 2.5)
        precondition(PlaybackRatePolicy.adjusted(2.5, by: 0.1) == 2.5)
        precondition(PlaybackRatePolicy.normalized(.infinity) == 1)
        precondition(PlaybackRatePolicy.supportedRates.first == 1)
        precondition(PlaybackRatePolicy.supportedRates.last == 2.5)
        precondition(PlaybackRatePolicy.supportedRates.count == 16)
        precondition(PlaybackAudioPolicy.timePitchAlgorithm == .timeDomain)
        precondition(!PlaybackAudioPolicy.waitsToMinimizeStalling)
        let pausedChapterSeek = PlayerSeekRequest(time: 60, shouldPlay: false)
        let playingChapterSeek = PlayerSeekRequest(time: 120, shouldPlay: true)
        precondition(!pausedChapterSeek.shouldPlay)
        precondition(playingChapterSeek.shouldPlay)
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: 10,
            isPrecise: true,
            isMomentum: false
        ) == 0.06)
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: -1,
            isPrecise: false,
            isMomentum: false
        ) == -0.05)
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 0,
            deltaY: 10,
            isPrecise: true,
            isMomentum: true
        ) == 0)
        precondition(PlayerVolumeScrollPolicy.adjustment(
            deltaX: 20,
            deltaY: 10,
            isPrecise: true,
            isMomentum: false
        ) == 0)
        precondition(PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: .began,
            momentumPhase: []
        ))
        precondition(PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: .changed,
            momentumPhase: []
        ))
        precondition(!PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: [],
            momentumPhase: []
        ))
        precondition(!PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: .ended,
            momentumPhase: []
        ))
        precondition(!PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: true,
            phase: [],
            momentumPhase: .changed
        ))
        precondition(PlayerVolumeScrollEventPolicy.shouldAdjust(
            isPrecise: false,
            phase: [],
            momentumPhase: []
        ))
        precondition(PictureInPicturePolicy.shouldStart(
            isPrimarySurfaceVisible: false,
            isPlaying: true,
            reachedEnd: false,
            isAlreadyActive: false,
            isExternalPlaybackActive: false
        ))
        let mediaKeyDown = (16 << 16) | (0xA << 8)
        let mediaKeyUp = (16 << 16) | (0xB << 8)
        let mediaKeyRepeat = mediaKeyDown | 0x1
        precondition(HardwareMediaKeyEventPolicy.action(
            subtype: 8,
            data1: mediaKeyDown
        ) == .togglePlayback)
        precondition(HardwareMediaKeyEventPolicy.action(
            subtype: 8,
            data1: (17 << 16) | (0xA << 8)
        ) == .skip(10))
        precondition(HardwareMediaKeyEventPolicy.action(
            subtype: 8,
            data1: (18 << 16) | (0xA << 8)
        ) == .skip(-10))
        precondition(HardwareMediaKeyEventPolicy.action(subtype: 8, data1: mediaKeyUp) == nil)
        precondition(HardwareMediaKeyEventPolicy.action(subtype: 8, data1: mediaKeyRepeat) == nil)
        precondition(HardwareMediaKeyEventPolicy.action(subtype: 0, data1: mediaKeyDown) == nil)
        precondition(!PictureInPicturePolicy.shouldStart(
            isPrimarySurfaceVisible: true,
            isPlaying: true,
            reachedEnd: false,
            isAlreadyActive: false,
            isExternalPlaybackActive: false
        ))
        precondition(!PictureInPicturePolicy.shouldStart(
            isPrimarySurfaceVisible: false,
            isPlaying: false,
            reachedEnd: false,
            isAlreadyActive: false,
            isExternalPlaybackActive: false
        ))
        precondition(!PictureInPicturePolicy.shouldStart(
            isPrimarySurfaceVisible: false,
            isPlaying: true,
            reachedEnd: true,
            isAlreadyActive: false,
            isExternalPlaybackActive: false
        ))
        precondition(!PictureInPicturePolicy.shouldStart(
            isPrimarySurfaceVisible: false,
            isPlaying: true,
            reachedEnd: false,
            isAlreadyActive: true,
            isExternalPlaybackActive: false
        ))
        precondition(!PictureInPicturePolicy.shouldStart(
            isPrimarySurfaceVisible: false,
            isPlaying: true,
            reachedEnd: false,
            isAlreadyActive: false,
            isExternalPlaybackActive: true
        ))

        let screenFrame = NSRect(x: 100, y: 50, width: 1_200, height: 800)
        let floatingFrame = FloatingPlayerLayout.frame(in: screenFrame)
        precondition(floatingFrame.maxX == screenFrame.maxX - FloatingPlayerLayout.margin)
        precondition(floatingFrame.minY == screenFrame.minY + FloatingPlayerLayout.margin)
        precondition(floatingFrame.size == FloatingPlayerLayout.size)

        let panelProbe = makeFloatingPanel(in: screenFrame)
        panelProbe.layoutIfNeeded()
        panelProbe.contentView?.layoutSubtreeIfNeeded()
        let contentSize = panelProbe.contentView?.bounds.size ?? .zero
        precondition(
            abs(contentSize.width - FloatingPlayerLayout.size.width) < 1
                && abs(contentSize.height - FloatingPlayerLayout.size.height) < 1,
            "悬浮窗内容区必须是完整 \(FloatingPlayerLayout.size)，实际 \(contentSize) 窗口 \(panelProbe.frame.size)"
        )
        precondition(
            panelProbe.frame.maxX <= screenFrame.maxX,
            "悬浮窗右缘不得超出可见区域，frame=\(panelProbe.frame) 可见=\(screenFrame)"
        )
        precondition(
            panelProbe.frame.minY >= screenFrame.minY,
            "悬浮窗底缘不得超出可见区域，frame=\(panelProbe.frame) 可见=\(screenFrame)"
        )
        panelProbe.close()

        let nowPlayingSnapshot = PlaybackSnapshot(
            currentTime: 42,
            duration: 120,
            isPlaying: true,
            playbackRate: 1.5
        )
        let nowPlayingInfo = NowPlayingInfoBuilder.make(
            title: "Test video",
            author: "Test author",
            snapshot: nowPlayingSnapshot
        )
        precondition(nowPlayingInfo[MPMediaItemPropertyTitle] as? String == "Test video")
        precondition(nowPlayingInfo[MPMediaItemPropertyArtist] as? String == "Test author")
        precondition(nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42)
        precondition(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)

        let suiteName = "seesee.PlaybackCommandCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        precondition(PlaybackRatePreference.load(from: defaults) == 1)
        PlaybackRatePreference.save(1.7, to: defaults)
        precondition(PlaybackRatePreference.load(from: defaults) == 1.7)
        defaults.set(99, forKey: "playbackRate")
        precondition(PlaybackRatePreference.load(from: defaults) == 2.5)
        precondition(PlaybackVolumePreference.load(from: defaults) == 1)
        PlaybackVolumePreference.save(0.42, to: defaults)
        precondition(PlaybackVolumePreference.load(from: defaults) == 0.42)
        PlaybackVolumePreference.save(99, to: defaults)
        precondition(PlaybackVolumePreference.load(from: defaults) == 1)
        defaults.removePersistentDomain(forName: suiteName)

        var received: [Double] = []
        var toggleCount = 0
        var requestedPlayingStates: [Bool] = []
        var muteCount = 0
        var rateAdjustments: [Double] = []
        var selectedRates: [Double] = []
        var fullscreenToggleCount = 0
        var fullscreenExitCount = 0
        let routePlayer = AVPlayer()
        let token = PlaybackCommandCenter.shared.register(
            player: routePlayer,
            skip: { received.append($0) },
            toggle: { toggleCount += 1 },
            setPlaying: { requestedPlayingStates.append($0) },
            mute: { muteCount += 1 },
            adjustRate: { rateAdjustments.append($0) },
            setRate: { selectedRates.append($0) },
            toggleFullscreen: {
                fullscreenToggleCount += 1
                return true
            },
            exitFullscreen: {
                fullscreenExitCount += 1
                return true
            }
        )
        precondition(PlaybackCommandCenter.shared.hasActivePlayer)
        precondition(PlaybackCommandCenter.shared.isActive(token))
        precondition(PlaybackCommandCenter.shared.activeRoutePlayer === routePlayer)
        precondition(PlaybackCommandCenter.shared.skip(by: -10))
        precondition(PlaybackCommandCenter.shared.skip(by: 10))
        precondition(PlaybackCommandCenter.shared.togglePlayback())
        precondition(PlaybackCommandCenter.shared.play())
        precondition(PlaybackCommandCenter.shared.pause())
        precondition(PlaybackCommandCenter.shared.toggleMute())
        precondition(PlaybackCommandCenter.shared.adjustPlaybackRate(by: 0.1))
        precondition(PlaybackCommandCenter.shared.adjustPlaybackRate(by: -0.1))
        precondition(PlaybackCommandCenter.shared.setPlaybackRate(to: 1.7))
        precondition(PlaybackCommandCenter.shared.setPlaybackRate(to: 99))
        precondition(PlaybackCommandCenter.shared.toggleFullscreen())
        precondition(PlaybackCommandCenter.shared.exitFullscreen())
        precondition(received == [-10, 10])
        precondition(toggleCount == 1)
        precondition(requestedPlayingStates == [true, false])
        precondition(muteCount == 1)
        precondition(rateAdjustments == [0.1, -0.1])
        precondition(selectedRates == [1.7, 2.5])
        precondition(fullscreenToggleCount == 1)
        precondition(fullscreenExitCount == 1)
        PlaybackCommandCenter.shared.unregister(token)
        precondition(!PlaybackCommandCenter.shared.hasActivePlayer)
        precondition(!PlaybackCommandCenter.shared.isActive(token))
        precondition(PlaybackCommandCenter.shared.activeRoutePlayer == nil)
        precondition(!PlaybackCommandCenter.shared.skip(by: 10))
        precondition(!PlaybackCommandCenter.shared.togglePlayback())
        precondition(!PlaybackCommandCenter.shared.play())
        precondition(!PlaybackCommandCenter.shared.pause())
        precondition(!PlaybackCommandCenter.shared.toggleMute())
        precondition(!PlaybackCommandCenter.shared.adjustPlaybackRate(by: 0.1))
        precondition(!PlaybackCommandCenter.shared.setPlaybackRate(to: 1.5))
        precondition(!PlaybackCommandCenter.shared.toggleFullscreen())
        precondition(!PlaybackCommandCenter.shared.exitFullscreen())
        print("playback_command_check=passed")
    }

    private static func subtitleTextFields(in view: NSView) -> [NSTextField] {
        var fields: [NSTextField] = []
        if let field = view as? NSTextField,
           !field.isHidden,
           !field.stringValue.isEmpty {
            fields.append(field)
        }
        for child in view.subviews {
            fields.append(contentsOf: subtitleTextFields(in: child))
        }
        return fields
    }

    private static func makeFloatingPanel(in visibleFrame: NSRect) -> NSPanel {
        let floatingView = FloatingVideoPlayerView()
        floatingView.controlsStyle = .floating
        floatingView.videoGravity = .resizeAspect
        floatingView.wantsLayer = true
        floatingView.layer?.cornerRadius = 16
        floatingView.layer?.masksToBounds = true
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: FloatingPlayerLayout.size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.minSize = NSSize(width: 280, height: 157.5)
        panel.contentView = floatingView
        panel.setFrame(FloatingPlayerLayout.frame(in: visibleFrame), display: false)
        return panel
    }
}
