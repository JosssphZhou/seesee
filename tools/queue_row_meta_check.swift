import Foundation

@main
struct QueueRowMetaCheck {
    static func main() {
        precondition(QueueRowMeta.sourceMark(for: "YouTube") == .youtube)
        precondition(QueueRowMeta.sourceMark(for: "哔哩哔哩") == .bilibili)
        precondition(QueueRowMeta.sourceMark(for: "小红书") == .xiaohongshu)
        precondition(QueueRowMeta.sourceMark(for: "X") == .x)
        precondition(QueueRowMeta.sourceMark(for: "Vimeo") == .unknown)
        precondition(QueueRowMeta.sourceMark(for: "视频") == .unknown)

        let knownMarks: [QueueRowMeta.SourceMark] = [
            QueueRowMeta.sourceMark(for: "YouTube"),
            QueueRowMeta.sourceMark(for: "哔哩哔哩"),
            QueueRowMeta.sourceMark(for: "小红书"),
            QueueRowMeta.sourceMark(for: "X"),
        ]
        precondition(Set(knownMarks).count == 4, "四个平台简标种类必须互不相同")

        let readyWithProgress = QueueRowMeta.statusText(state: .ready, progressLabel: "已下载")
        // 就绪态正常沉默，不显示任何状态文字。
        precondition(
            !readyWithProgress.contains("续播"),
            "就绪态不得出现续播文案，实际：\(readyWithProgress)"
        )
        precondition(readyWithProgress.isEmpty)
        precondition(QueueRowMeta.statusText(state: .ready, progressLabel: "续播 99:28").isEmpty)

        // 失败原因人话化：网络类归一句话，未知报错走兜底，空值有缺省。
        precondition(QueueRowMeta.failureSummary(from: "ERROR: [generic] x: Unable to download webpage: [SSL: UNEXPECTED_EOF] ...") == "网络连接中断，无法获取视频页面")
        precondition(QueueRowMeta.failureSummary(from: "HTTP Error 404: Not Found") == "视频不存在或已下架")
        precondition(QueueRowMeta.failureSummary(from: "Sign in to confirm your age") == "视频需要登录或没有访问权限")
        precondition(QueueRowMeta.failureSummary(from: "某种没见过的报错") == "下载工具报错，展开详情查看原文")
        precondition(QueueRowMeta.failureSummary(from: nil) == "未知的下载错误")

        // 标题剥作者前缀：作者已单独显示时去重，改名与数据层仍用原始标题。
        precondition(QueueRowMeta.displayTitle(title: "Codez - SpaceXAI engineer", author: "Codez") == "SpaceXAI engineer")
        precondition(QueueRowMeta.displayTitle(title: "Codez – 长破折号case", author: "Codez") == "长破折号case")
        precondition(QueueRowMeta.displayTitle(title: "Codez - SpaceXAI", author: "") == "Codez - SpaceXAI")
        precondition(QueueRowMeta.displayTitle(title: "SpaceXAI engineer", author: "Codez") == "SpaceXAI engineer")
        precondition(QueueRowMeta.displayTitle(title: "Codez - ", author: "Codez") == "Codez - ")
        precondition(QueueRowMeta.displayTitle(title: "Codezilla - 大战哥斯拉", author: "Codez") == "Codezilla - 大战哥斯拉")

        precondition(QueueRowMeta.statusText(state: .queued, progressLabel: "排队中") == "排队中")
        precondition(QueueRowMeta.statusText(state: .queued, progressLabel: "低电量模式已暂停") == "低电量模式已暂停")
        precondition(QueueRowMeta.statusText(state: .queued, progressLabel: "等待网络连接") == "等待网络连接")
        precondition(QueueRowMeta.statusText(state: .queued, progressLabel: "等待下载槽位") == "等待下载槽位")
        precondition(QueueRowMeta.statusText(state: .downloading, progressLabel: "下载中…") == "下载中…")
        precondition(QueueRowMeta.statusText(state: .failed, progressLabel: "重试 3 次后失败") == "重试 3 次后失败")

        precondition(QueueRowMeta.localFileToReveal(path: nil, exists: { _ in true }) == nil)
        precondition(QueueRowMeta.localFileToReveal(path: "", exists: { _ in true }) == nil)
        precondition(QueueRowMeta.localFileToReveal(path: "/tmp/gone.mp4", exists: { _ in false }) == nil)
        precondition(QueueRowMeta.localFileToReveal(path: "/tmp/ready.mp4", exists: { $0 == "/tmp/ready.mp4" }) == "/tmp/ready.mp4")
        precondition(
            QueueRowMeta.reorderDragThreshold >= 10,
            "拖拽阈值过小会把单击认成排序"
        )

        let states: [DownloadState] = [.queued, .downloading, .ready, .failed]
        for state in states {
            for canReveal in [false, true] {
                let items = QueueRowMeta.contextMenuItems(
                    state: state,
                    canRevealLocalFile: canReveal
                )
                precondition(
                    items.contains(.rename),
                    "任意队列行右键菜单都必须有重命名：state=\(state) reveal=\(canReveal)"
                )
                precondition(QueueRowMeta.visibleTitle(for: .rename, isWatched: false) == "重命名")
            }
        }

        let failedMenu = QueueRowMeta.contextMenuItems(
            state: .failed,
            canRevealLocalFile: false
        )
        precondition(failedMenu == [
            .toggleWatched, .rename, .retryDownload, .openOriginal, .divider, .delete
        ])

        let readyWithFile = QueueRowMeta.contextMenuItems(
            state: .ready,
            canRevealLocalFile: true
        )
        precondition(readyWithFile == [
            .toggleWatched, .rename, .openOriginal, .revealInFinder, .divider, .delete
        ])
        precondition(QueueRowMeta.visibleTitle(for: .toggleWatched, isWatched: true) == "移回队列")
        precondition(QueueRowMeta.visibleTitle(for: .toggleWatched, isWatched: false) == "标记已看")

        func applyClick(
            _ state: inout QueueRowMeta.TitleClickState,
            isSelected: Bool,
            clickCount: Int,
            continuesPair: Bool
        ) -> QueueRowMeta.TitleClickAction {
            let result = QueueRowMeta.handleTitleClick(
                state: state,
                isSelected: isSelected,
                clickCount: clickCount,
                continuesPair: continuesPair
            )
            state = result.0
            return result.1
        }

        var clickState = QueueRowMeta.TitleClickState()
        precondition(
            applyClick(&clickState, isSelected: true, clickCount: 1, continuesPair: false) == .select
        )
        precondition(
            applyClick(&clickState, isSelected: true, clickCount: 2, continuesPair: true) == .beginEditing,
            "已选中行双击必须进编辑"
        )

        clickState = QueueRowMeta.TitleClickState()
        _ = applyClick(&clickState, isSelected: true, clickCount: 1, continuesPair: false)
        precondition(
            applyClick(&clickState, isSelected: true, clickCount: 1, continuesPair: true) == .beginEditing,
            "已选中行两击都报 clickCount=1 仍须进编辑"
        )

        clickState = QueueRowMeta.TitleClickState()
        precondition(
            applyClick(&clickState, isSelected: false, clickCount: 1, continuesPair: false) == .select
        )
        precondition(
            applyClick(&clickState, isSelected: true, clickCount: 2, continuesPair: true) == .select,
            "未选中行双击：第二击读到重绘后的选中态，也不得进编辑"
        )

        clickState = QueueRowMeta.TitleClickState()
        _ = applyClick(&clickState, isSelected: false, clickCount: 1, continuesPair: false)
        precondition(
            applyClick(&clickState, isSelected: true, clickCount: 1, continuesPair: true) == .select,
            "未选中行两击都报 clickCount=1：选择变化后仍只选中"
        )

        clickState = QueueRowMeta.TitleClickState()
        _ = applyClick(&clickState, isSelected: true, clickCount: 1, continuesPair: false)
        precondition(
            applyClick(&clickState, isSelected: true, clickCount: 1, continuesPair: false) == .select,
            "超过双击间隔的第二次单击不得进编辑"
        )

        clickState = QueueRowMeta.TitleClickState()
        precondition(
            applyClick(&clickState, isSelected: false, clickCount: 2, continuesPair: false) == .select,
            "单次事件即使 clickCount>=2，也要用第一击选中态"
        )

        precondition(
            QueueRowMeta.titleEditCommit(reason: .submit, draft: "  新标题  ") == .save("新标题")
        )
        precondition(
            QueueRowMeta.titleEditCommit(reason: .submit, draft: "   ") == .discard,
            "回车空名不得保存"
        )
        precondition(
            QueueRowMeta.titleEditCommit(reason: .escape, draft: "改过的名字") == .discard,
            "Esc 必须恢复原名，不保存"
        )
        precondition(
            QueueRowMeta.titleEditCommit(reason: .escape, draft: "  新标题  ") == .discard
        )
        precondition(
            QueueRowMeta.titleEditCommit(reason: .focusLost, draft: "  点走保存  ") == .save("点走保存")
        )
        precondition(
            QueueRowMeta.titleEditCommit(reason: .focusLost, draft: " \n ") == .discard
        )

        print("queue_row_meta_check=passed")
    }
}
