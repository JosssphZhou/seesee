import Foundation

enum DigestJumpPlayback {
    /// 句块、目录章节、键盘回车：暂停时也开播。
    static func jumpShouldPlay() -> Bool { true }

    /// 拖进度条、左右方向键：保持当前播放态。
    static func scrubShouldPlay(currentlyPlaying: Bool) -> Bool { currentlyPlaying }
}
