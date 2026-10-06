import Foundation

@main
struct DigestNotesCheck {
    static func main() throws {
        checkFileNaming()
        try checkRoundTripAndDelete()
        try checkCommentRoundTrip()
        try checkLegacyFileWithoutComment()
        checkCommentNormalization()
        checkCorruptAndMissing()
        checkCaptureWholeBlock()
        checkCaptureSpansTwoCues()
        print("digest_notes_check=passed")
    }

    private static func checkFileNaming() {
        let id = UUID(uuidString: "9D0A346E-068C-41CE-B3FC-938A773AADC9")!
        let folder = URL(fileURLWithPath: "/tmp/seesee-media", isDirectory: true)
        let url = DigestNotesStore.fileURL(itemID: id, in: folder)
        precondition(
            url.lastPathComponent == "9D0A346E-068C-41CE-B3FC-938A773AADC9.notes.json",
            "笔记 sidecar 须为 {UUID}.notes.json"
        )
        precondition(url.lastPathComponent.hasPrefix(id.uuidString + "."))
    }

    private static func checkRoundTripAndDelete() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let itemID = UUID()
        let note = DigestNote(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            time: 75.5,
            text: "这段在讲注意力机制",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try DigestNotesStore.save([note], itemID: itemID, folder: folder)

        let loaded = DigestNotesStore.load(itemID: itemID, folder: folder)
        precondition(loaded.count == 1)
        precondition(loaded[0].id == note.id)
        precondition(loaded[0].time == 75.5)
        precondition(loaded[0].text == "这段在讲注意力机制")
        precondition(loaded[0].createdAt.timeIntervalSince1970 == 1_700_000_000)

        let remaining = loaded.filter { $0.id != note.id }
        try DigestNotesStore.save(remaining, itemID: itemID, folder: folder)
        precondition(DigestNotesStore.load(itemID: itemID, folder: folder).isEmpty, "删除后列表应为空")
        precondition(loaded[0].comment == nil, "未写批语时 comment 为空")
    }

    private static func checkCommentRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-notes-comment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let itemID = UUID()
        let note = DigestNote(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            time: 12.5,
            text: "Hello world.\n大家好。",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            comment: "这句是关键"
        )
        try DigestNotesStore.save([note], itemID: itemID, folder: folder)

        let loaded = DigestNotesStore.load(itemID: itemID, folder: folder)
        precondition(loaded.count == 1)
        precondition(loaded[0].comment == "这句是关键", "批语必须落盘并读回")
        precondition(loaded[0].text == note.text)
        precondition(DigestNoteComment.shouldDisplay(loaded[0].comment))
    }

    private static func checkLegacyFileWithoutComment() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-notes-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let itemID = UUID(uuidString: "9D0A346E-068C-41CE-B3FC-938A773AADC9")!
        let url = DigestNotesStore.fileURL(itemID: itemID, in: folder)
        let legacy = """
        [
          {
            "createdAt" : "2023-11-14T22:13:20Z",
            "id" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "text" : "探索分支旧笔记",
            "time" : 8
          }
        ]
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let loaded = DigestNotesStore.load(itemID: itemID, folder: folder)
        precondition(loaded.count == 1, "无批语字段的旧文件必须能读")
        precondition(loaded[0].text == "探索分支旧笔记")
        precondition(loaded[0].time == 8)
        precondition(loaded[0].comment == nil, "旧文件缺字段时批语为空")
        precondition(!DigestNoteComment.shouldDisplay(loaded[0].comment))
    }

    private static func checkCommentNormalization() {
        precondition(DigestNoteComment.normalized(nil) == nil)
        precondition(DigestNoteComment.normalized("   ") == nil)
        precondition(DigestNoteComment.normalized("\n") == nil)
        precondition(DigestNoteComment.normalized("  记下这句  ") == "记下这句")
        precondition(DigestNoteComment.normalized("一行\n两行") == "一行 两行")
        precondition(!DigestNoteComment.shouldDisplay(nil))
        precondition(!DigestNoteComment.shouldDisplay("   "))
        precondition(DigestNoteComment.shouldDisplay("有内容"))
    }

    private static func checkCorruptAndMissing() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).notes.json")
        precondition(DigestNotesStore.read(from: missing) == .missing)
        precondition(DigestNotesStore.load(from: missing).isEmpty)

        let folder = FileManager.default.temporaryDirectory
        let corrupt = folder.appendingPathComponent("digest-notes-corrupt-\(UUID().uuidString).json")
        try? "not-json".write(to: corrupt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        precondition(DigestNotesStore.read(from: corrupt) == .corrupt, "损坏文件必须标为 corrupt")
        let before = try? String(contentsOf: corrupt, encoding: .utf8)
        _ = DigestNotesStore.load(from: corrupt)
        let after = try? String(contentsOf: corrupt, encoding: .utf8)
        precondition(before == after, "读取损坏文件不得覆盖原件")
    }

    private static func checkCaptureWholeBlock() {
        let cue = DigestNoteSource(
            startTime: 68,
            text: "This is very likely the reason.\n这很可能就是原因。"
        )
        let saved = DigestNoteCapture.sources(selected: "很可能", hintIndex: 0, cues: [cue])
        precondition(saved.count == 1)
        precondition(saved[0].text == cue.text, "选区只决定哪一句，必须存整句")
        precondition(saved[0].startTime == 68)
        precondition(!saved[0].text.contains("很可能") || saved[0].text.count > 3)
    }

    private static func checkCaptureSpansTwoCues() {
        let first = DigestNoteSource(startTime: 10, text: "Hello world.\n你好世界。")
        let second = DigestNoteSource(startTime: 14, text: "This is likely.\n这很可能。")
        let selected = "世界。\nThis is likely."
        let saved = DigestNoteCapture.sources(selected: selected, hintIndex: 0, cues: [first, second])
        precondition(saved.count == 2, "跨两句必须两句都存，实际 \(saved.count)")
        precondition(saved[0].startTime == 10)
        precondition(saved[1].startTime == 14)
    }
}
