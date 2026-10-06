import Foundation

@main
struct PlayerReadyCheck {
    static func main() {
        precondition(
            PlayerReadyDecision.isPlayable(state: .ready, localFileExists: true),
            "就绪且本地文件存在时必须可播放"
        )
        precondition(
            !PlayerReadyDecision.isPlayable(state: .ready, localFileExists: false),
            "就绪但本地文件不存在时不可播放"
        )
        precondition(
            !PlayerReadyDecision.isPlayable(state: .downloading, localFileExists: true),
            "下载中即使文件已出现也不可播放"
        )
        precondition(
            !PlayerReadyDecision.isPlayable(state: .queued, localFileExists: false),
            "排队中不可播放"
        )
        precondition(
            !PlayerReadyDecision.isPlayable(state: .failed, localFileExists: false),
            "失败态不可播放"
        )

        let becameReady = PlayerReadyDecision.loadSignal(
            previousPlayable: PlayerReadyDecision.isPlayable(state: .downloading, localFileExists: false),
            currentPlayable: PlayerReadyDecision.isPlayable(state: .ready, localFileExists: true)
        )
        precondition(becameReady == .load, "选中条目由下载完成转为就绪必须发出装载信号")

        let selectedAlreadyReady = PlayerReadyDecision.loadSignal(
            previousPlayable: false,
            currentPlayable: PlayerReadyDecision.isPlayable(state: .ready, localFileExists: true)
        )
        precondition(selectedAlreadyReady == .load, "切回已就绪条目必须发出装载信号")

        let stillReady = PlayerReadyDecision.loadSignal(
            previousPlayable: PlayerReadyDecision.isPlayable(state: .ready, localFileExists: true),
            currentPlayable: PlayerReadyDecision.isPlayable(state: .ready, localFileExists: true)
        )
        precondition(stillReady == .none, "已可播放时不得因界面刷新再次装载")

        let stillDownloading = PlayerReadyDecision.loadSignal(
            previousPlayable: PlayerReadyDecision.isPlayable(state: .queued, localFileExists: false),
            currentPlayable: PlayerReadyDecision.isPlayable(state: .downloading, localFileExists: false)
        )
        precondition(stillDownloading == .none, "仍在下载时不得发出装载信号")

        let lostFile = PlayerReadyDecision.loadSignal(
            previousPlayable: PlayerReadyDecision.isPlayable(state: .ready, localFileExists: true),
            currentPlayable: PlayerReadyDecision.isPlayable(state: .ready, localFileExists: false)
        )
        precondition(lostFile == .unload, "本地文件消失后必须卸下播放器")

        print("player_ready_check=passed")
    }
}
