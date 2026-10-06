import AVFoundation
import Foundation

@main
struct DisplaySleepCheck {
    static func main() {
        // AVPlayer 在 macOS 上默认不阻止熄屏，seesee 创建播放器时必须打开这一项。
        precondition(!AVPlayer().preventsDisplaySleepDuringVideoPlayback)

        let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
        let player = PlaybackAudioPolicy.makePlayer(playing: item)
        precondition(player.preventsDisplaySleepDuringVideoPlayback)
        precondition(player.currentItem === item)
        precondition(player.allowsExternalPlayback)
        precondition(player.automaticallyWaitsToMinimizeStalling == PlaybackAudioPolicy.waitsToMinimizeStalling)
        precondition(item.audioTimePitchAlgorithm == PlaybackAudioPolicy.timePitchAlgorithm)
        print("display_sleep_check=passed")
    }
}
