import Foundation

/// 删除接线回归：经**真实生产入口** `QueueStore.remove` 删视频，断言划线和旧版本留下的问答、批注、目录记录一并清掉。
/// 删掉 `remove` 里的 `deleteLocalFiles(for:)` 调用（或其中的清理）时本用例转红。
@main
struct QARemoveCheck {
    static func main() async throws {
        try await checkRemoveDeletesSidecar()
        try await checkRemoveKeepsMediaWhenNotDeleting()
        print("qa_remove_check=passed")
    }

    /// remove(deleteMedia: true) 必须删掉 <id>.* 的全部文件，包括旧版本留下的 qa.json、annotations.json、digest.json。
    private static func checkRemoveDeletesSidecar() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let id = UUID()
        let qaURL = env.mediaFolder.appendingPathComponent("\(id.uuidString).qa.json")
        let annotationURL = env.mediaFolder.appendingPathComponent("\(id.uuidString).annotations.json")
        let digestURL = env.mediaFolder.appendingPathComponent("\(id.uuidString).digest.json")
        let notesURL = env.mediaFolder.appendingPathComponent("\(id.uuidString).notes.json")
        let videoURL = env.mediaFolder.appendingPathComponent("\(id.uuidString).mp4")
        try Data("[]".utf8).write(to: qaURL)
        try Data("[]".utf8).write(to: annotationURL)
        try Data("{\"schemaVersion\":3}".utf8).write(to: digestURL)
        try Data("[]".utf8).write(to: notesURL)
        try Data("video".utf8).write(to: videoURL)
        precondition(FileManager.default.fileExists(atPath: qaURL.path))
        precondition(FileManager.default.fileExists(atPath: annotationURL.path))
        precondition(FileManager.default.fileExists(atPath: digestURL.path))

        let store = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder)
        }
        await MainActor.run { store.remove(id, deleteMedia: true) }

        try await waitUntilGone(qaURL)
        try await waitUntilGone(annotationURL)
        try await waitUntilGone(digestURL)
        precondition(!FileManager.default.fileExists(atPath: qaURL.path), "remove 必须删除 qa.json（删除接线）")
        precondition(
            !FileManager.default.fileExists(atPath: annotationURL.path),
            "remove 必须删除 annotations.json（批注旁路文件）"
        )
        precondition(!FileManager.default.fileExists(atPath: digestURL.path), "remove 必须删除目录 sidecar")
        precondition(!FileManager.default.fileExists(atPath: notesURL.path), "remove 必须删除划线 notes.json")
        precondition(!FileManager.default.fileExists(atPath: videoURL.path), "remove 必须删除视频文件")
    }

    /// remove(deleteMedia: false) 不得删本地文件（含 qa.json），只从队列移除。
    private static func checkRemoveKeepsMediaWhenNotDeleting() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let id = UUID()
        let qaURL = env.mediaFolder.appendingPathComponent("\(id.uuidString).qa.json")
        let annotationURL = env.mediaFolder.appendingPathComponent("\(id.uuidString).annotations.json")
        let digestURL = env.mediaFolder.appendingPathComponent("\(id.uuidString).digest.json")
        try Data("[]".utf8).write(to: qaURL)
        try Data("[]".utf8).write(to: annotationURL)
        try Data("{\"schemaVersion\":3}".utf8).write(to: digestURL)

        let store = await MainActor.run {
            QueueStore(dataFile: env.dataFile, mediaFolder: env.mediaFolder)
        }
        await MainActor.run { store.remove(id, deleteMedia: false) }

        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(FileManager.default.fileExists(atPath: qaURL.path), "deleteMedia=false 不得删除 qa.json")
        precondition(
            FileManager.default.fileExists(atPath: annotationURL.path),
            "deleteMedia=false 不得删除 annotations.json"
        )
        precondition(
            FileManager.default.fileExists(atPath: digestURL.path),
            "deleteMedia=false 不得删除 digest.json"
        )
    }

    private struct Env {
        let root: URL
        let mediaFolder: URL
        let dataFile: URL
    }

    private static func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-remove-\(UUID().uuidString)", isDirectory: true)
        let mediaFolder = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        return Env(root: root, mediaFolder: mediaFolder, dataFile: root.appendingPathComponent("queue.json"))
    }

    private static func waitUntilGone(_ url: URL) async throws {
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
