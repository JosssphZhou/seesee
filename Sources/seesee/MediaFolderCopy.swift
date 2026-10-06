import Foundation

enum MediaFolderCopy {
    static let disconnected = "存放位置未连接"
    static let changeButton = "更改…"
    static let downloadingBlock = "有视频正在下载，下载完成后再更改存放位置"
    static let sourceDisconnected = "片库存放位置未连接，无法搬移"
    static let destinationDisconnected = "目标存放位置未连接"
    static let destinationOverlapsLibrary = "新位置不能放在当前片库里面，也不能包含当前片库"
    static let queueUnreadable = "queue.json 读不出来，无法判断片库状态，没有改动任何文件"
    static let interrupted = "搬移中断"
    static let previousFolderKept = "旧位置还留着一份"
    static let revealInFinder = "在访达中显示"
    static let pendingMoveRolledBack = "上次更改存放位置没有完成，仍在使用原来的位置"
    static let pendingMoveUnreadable = "上次更改存放位置的记录读不出来，没有改动任何文件"

    static func progress(completed: Int, total: Int) -> String {
        "正在搬移视频（已完成 \(completed) / \(total)）"
    }

    static func failure(_ reason: String) -> String {
        "搬移没有完成，原来的视频都还在：\(reason)"
    }

    static func pendingMoveNotRestored(_ reason: String) -> String {
        "上次更改存放位置没有完成，退回原来的位置时出错：\(reason)"
    }

    static func pendingDestinationDisconnected(_ path: String) -> String {
        "\(pendingMoveRolledBack)。新位置 \(path) 未连接，接上后会清掉那里复制了一半的文件"
    }

    static func pendingCleanupFailed(path: String, reason: String) -> String {
        "\(pendingMoveRolledBack)。新位置 \(path) 里复制了一半的文件没能清掉：\(reason)"
    }
}

struct MediaLibraryMoveProgress: Equatable {
    var completed: Int
    var total: Int

    var text: String {
        MediaFolderCopy.progress(completed: completed, total: total)
    }
}
