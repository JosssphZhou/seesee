import Foundation

@main
struct DigestJumpCheck {
    static func main() {
        precondition(DigestJumpPlayback.jumpShouldPlay(), "句块 / 目录 / 回车必须开播")
        precondition(
            DigestJumpPlayback.scrubShouldPlay(currentlyPlaying: false) == false,
            "拖进度条与左右方向键在暂停时不得开播"
        )
        precondition(
            DigestJumpPlayback.scrubShouldPlay(currentlyPlaying: true) == true,
            "播放中拖进度条须保持播放"
        )
        print("digest_jump_check=passed")
    }
}
