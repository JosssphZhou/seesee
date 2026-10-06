import Foundation

@main
struct DigestSessionCheck {
    static func main() async throws {
        checkEmptySurface()
        checkCopyIsProductVoice()
        try await MainActor.run {
            try checkLaunchSelectionLoadsSidecars()
            try checkSwitchThreeVideosIsolated()
            try checkLegacyAIFilesUntouched()
            try checkSaveFailureReverts()
            try checkCorruptLoadDoesNotOverwrite()
            try checkCommentCancelKeepsOriginal()
        }
        print("digest_session_check=passed")
    }

    private static func checkEmptySurface() {
        precondition(DigestCopy.emptyTitle == "暂无字幕")
        precondition(DigestCopy.emptyDetail(hasSubtitleSource: false) == DigestCopy.emptyUnavailableDetail)
        precondition(DigestCopy.emptyDetail(hasSubtitleSource: true) == DigestCopy.emptyLoadingDetail)
        precondition(!DigestCopy.showsBook(cueCount: 0))
        precondition(DigestCopy.showsBook(cueCount: 1))
        precondition(!DigestCopy.showsDigestActions(cueCount: 0), "无字幕不得出现划线入口")
        precondition(DigestCopy.showsDigestActions(cueCount: 1))
    }

    private static func checkCopyIsProductVoice() {
        let banned = ["验收", "任务书", "实现者", "ticket", "spec"]
        let phrases = [
            DigestCopy.saveFailed,
            DigestCopy.fileCorrupt,
            DigestCopy.emptyTitle,
            DigestCopy.emptyLoadingDetail,
            DigestCopy.emptyUnavailableDetail
        ]
        for phrase in phrases {
            for word in banned {
                precondition(!phrase.contains(word), "状态文案不得含任务描述措辞「\(word)」：\(phrase)")
            }
        }
    }

    @MainActor
    private static func checkLaunchSelectionLoadsSidecars() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let itemID = UUID()
        let note = DigestNote(id: UUID(), time: 6, text: "Hello world.\n大家好。", createdAt: Date(), comment: "启动批语")
        try DigestNotesStore.save([note], itemID: itemID, folder: folder)

        let session = DigestSession()
        session.ensureLoaded(itemID: itemID, folder: folder)
        precondition(session.notes.first?.comment == "启动批语", "启动首选条目必须加载划线")
        session.ensureLoaded(itemID: itemID, folder: folder)
        precondition(session.notes.first?.comment == "启动批语", "同一条目再次确保加载不得清空")
    }

    @MainActor
    private static func checkSwitchThreeVideosIsolated() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let ids = [UUID(), UUID(), UUID()]
        let notes = [
            DigestNote(id: UUID(), time: 1, text: "视频甲", createdAt: Date(), comment: "甲批语"),
            DigestNote(id: UUID(), time: 2, text: "视频乙", createdAt: Date(), comment: "乙批语"),
            DigestNote(id: UUID(), time: 3, text: "视频丙", createdAt: Date(), comment: "丙批语")
        ]
        for index in 0..<3 {
            try DigestNotesStore.save([notes[index]], itemID: ids[index], folder: folder)
        }

        let session = DigestSession()
        session.load(itemID: ids[0], folder: folder)
        session.showsHighlightsOnly = true
        precondition(session.notes.first?.text == "视频甲")
        precondition(session.showsHighlightsOnly)

        session.load(itemID: ids[1], folder: folder)
        precondition(!session.showsHighlightsOnly, "换视频必须退出只看划线")
        precondition(session.notes.first?.text == "视频乙", "乙的划线不得被甲污染")
        precondition(session.notes.first?.text != "视频甲")

        session.load(itemID: ids[2], folder: folder)
        precondition(session.notes.first?.comment == "丙批语")

        session.showsHighlightsOnly = true
        session.load(itemID: ids[0], folder: folder)
        precondition(!session.showsHighlightsOnly)
        precondition(session.notes.first?.text == "视频甲", "切回甲时痕迹必须还在")
    }

    /// 旧版本留下的问答、批注、目录记录：应用不再读写，划线和批语照常存取时这些文件一个字节都不变。
    @MainActor
    private static func checkLegacyAIFilesUntouched() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let itemID = UUID()
        let legacy: [(suffix: String, body: String)] = [
            ("qa.json", #"[{"question":"旧问题","answer":"旧回答","time":6}]"#),
            ("annotations.json", #"[{"time":6,"text":"Hello world.","explanation":"旧解释"}]"#),
            ("digest.json", #"{"schemaVersion":3,"payload":{"chapters":[]}}"#)
        ]
        for file in legacy {
            try Data(file.body.utf8).write(to: folder.appendingPathComponent("\(itemID.uuidString).\(file.suffix)"))
        }

        let session = DigestSession()
        session.load(itemID: itemID, folder: folder)
        let cue = VideoSubtitleCue(startTime: 6, endTime: 8, text: "Hello world.\n大家好。")
        _ = session.toggleHighlight(cue: cue)
        session.updateComment(noteID: session.notes[0].id, comment: "留着")
        session.load(itemID: itemID, folder: folder)
        precondition(session.notes.first?.comment == "留着", "划线和批语必须照常存取")

        for file in legacy {
            let url = folder.appendingPathComponent("\(itemID.uuidString).\(file.suffix)")
            let after = try Data(contentsOf: url)
            precondition(after == Data(file.body.utf8), "旧版本的 \(file.suffix) 不得被改动或删除")
        }
    }

    @MainActor
    private static func checkSaveFailureReverts() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-save-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let itemID = UUID()
        let session = DigestSession()
        session.load(itemID: itemID, folder: folder)
        let sidecar = DigestNotesStore.fileURL(itemID: itemID, in: folder)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        let cue = VideoSubtitleCue(startTime: 1, endTime: 2, text: "Hello world.\n大家好。")
        _ = session.toggleHighlight(cue: cue)
        precondition(session.persistMessage == DigestCopy.saveFailed, "保存失败须提示")
        precondition(session.notes.isEmpty, "保存失败须回退内存")
    }

    @MainActor
    private static func checkCorruptLoadDoesNotOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let itemID = UUID()
        let url = DigestNotesStore.fileURL(itemID: itemID, in: folder)
        try "not-json".write(to: url, atomically: true, encoding: .utf8)
        let session = DigestSession()
        session.load(itemID: itemID, folder: folder)
        precondition(session.persistMessage == DigestCopy.fileCorrupt)
        let after = try String(contentsOf: url, encoding: .utf8)
        precondition(after == "not-json", "损坏文件不得被覆盖")
    }

    @MainActor
    private static func checkCommentCancelKeepsOriginal() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-comment-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let itemID = UUID()
        let session = DigestSession()
        session.load(itemID: itemID, folder: folder)
        let cue = VideoSubtitleCue(startTime: 6, endTime: 8, text: "Hello world.\n大家好。")
        _ = session.toggleHighlight(cue: cue)
        let id = session.notes[0].id
        precondition(session.editingCommentNoteID == id, "划线后须进入批语编辑")
        session.updateComment(noteID: id, comment: "留下")
        precondition(session.notes[0].comment == "留下")
        session.beginEditComment(noteID: id)
        precondition(session.commentDraft == "留下", "重新打开须带出原文")
        session.commentDraft = "改了又取消"
        session.cancelEditComment()
        precondition(session.editingCommentNoteID == nil, "取消后须退出编辑")
        precondition(session.notes[0].comment == "留下", "取消不得改批语")
        session.beginEditComment(noteID: id)
        session.commentDraft = "新稿"
        session.commitCommentDraft()
        precondition(session.notes[0].comment == "新稿", "回车语义须保存草稿")
        session.beginEditComment(noteID: id)
        session.updateComment(noteID: id, comment: "   ")
        precondition(session.notes[0].comment == nil, "空批语不得保存")
        precondition(session.editingCommentNoteID == nil)
    }
}
