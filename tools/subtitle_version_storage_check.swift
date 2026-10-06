import AppKit
import Foundation

/// 构造字幕、真实队列读写；不启动应用、不操作用户数据。
@main
struct SubtitleVersionStorageCheck {
    struct Failed: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failed(message: message) }
    }
    struct Fixture {
        let root: URL
        let media: URL
        let file: URL
        let suite: String
        let id: UUID
        let initial: URL
        let active: URL
        @MainActor func store() -> QueueStore {
            QueueStore(dataFile: file, mediaFolder: media, defaults: UserDefaults(suiteName: suite)!, mountedVolumeURLs: [])
        }
        func clean() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }
    static func fixture(versioned: Bool = true, state: String? = nil) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ss-version-\(UUID().uuidString)")
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let id = UUID()
        let initial = media.appendingPathComponent("\(id.uuidString).zh.srt")
        let active = media.appendingPathComponent("\(id.uuidString).agent-1.srt")
        let initialText = "1\n00:00:00,000 --> 00:00:02,000\nWelcome.\n欢迎。\n\n2\n00:00:03,000 --> 00:00:06,000\nThis is a test.\n这是测试。\n"
        try Data(initialText.utf8).write(to: initial)
        try Data(initialText.replacingOccurrences(of: "欢迎。", with: "大家好。").utf8).write(to: active)
        var item: [String: Any] = ["id": id.uuidString, "urlString": "https://example.invalid/version", "title": "字幕版本检查", "author": "", "duration": 10, "addedAt": "2026-10-01T00:00:00Z", "state": "ready", "progress": 1, "progressLabel": "已下载", "subtitleFilePath": (versioned ? active : initial).path]
        if versioned {
            item["originalSubtitlePath"] = initial.path
            item["initialSubtitlePath"] = initial.path
            item["translationSource"] = "agent"
            item["initialTranslationSource"] = "youtube_auto"
            item["subtitleRevision"] = 1
        }
        if let state { item["transcriptionState"] = state }
        let file = root.appendingPathComponent("queue.json")
        try JSONSerialization.data(withJSONObject: [item], options: [.sortedKeys]).write(to: file)
        return Fixture(root: root, media: media, file: file, suite: "seesee.check.subtitle-version.\(UUID().uuidString)", id: id, initial: initial, active: active)
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("download-tracks") { try await checkDownloadedTracksRescan(); return }
        if CommandLine.arguments.contains("initial-cache") { try checkInitialDisplayReuse(); return }
        try await checkDownloadedTracksRescan()
        try await checkExternalRescan()
        let f = try fixture(); defer { f.clean() }
        let original = try Data(contentsOf: f.initial)
        let polished = try Data(contentsOf: f.active)
        let store = f.store()
        let path: String = await withCheckedContinuation { continuation in
            store.rescanLocalSubtitle(for: f.id) { continuation.resume(returning: $0) }
        }
        try check(path == f.active.path && store.item(with: f.id)?.subtitleFilePath == f.active.path, "重新打开条目不得按文件名切回初译")
        store.rename(f.id, to: "版本保存重载")
        try check(store.flushPendingSaves(), "字幕版本队列真正写盘")
        let reloaded = f.store()
        try check(reloaded.item(with: f.id)?.subtitleFilePath == f.active.path, "活动版本重载不丢失")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as! [[String: Any]]
        try check(object[0]["initialSubtitlePath"] as? String == f.initial.path && object[0]["subtitleRevision"] as? Int == 1, "版本和初译路径必须往返保留")
        try check(Data(contentsOf: f.initial) == original && Data(contentsOf: f.active) == polished, "重新打开和保存均不改字幕文件")
        let before = try reloaded.subtitleSnapshot(for: f.id)
        for text in ["把 a --> b 写成箭头。", "添加 <div> 标签。", "&lt;div&gt;", "&amp;", "&#39;", "&nbsp;", " 前后空白 "] {
            do {
                _ = try reloaded.writeSubtitleTranslations([.init(index: 0, translation: "第一句。"), .init(index: 1, translation: text)], revision: before.revision, for: f.id)
                throw Failed(message: "字幕解析特殊内容被错误接受：\(text)")
            } catch let failure as SubtitleVersionStore.Failure {
                try check(failure.code == "invalid_arguments" && failure.message.contains("index 1"), "特殊内容整批拒绝，并指出稳定句编号")
            }
            try check(try reloaded.subtitleSnapshot(for: f.id).revision == before.revision, "拒绝特殊内容不能部分写回")
        }
        let written = try reloaded.writeSubtitleTranslations([
            .init(index: 0, translation: "欢迎大家。"), .init(index: 1, translation: "这是一次测试。")
        ], revision: before.revision, for: f.id)
        try check(written.revision != before.revision, "每次整轨写回改变修订凭据")
        try check(written.cues.map { SubtitleVersionStore.split($0).original } == ["Welcome.", "This is a test."], "写回不能改原文")
        try check(written.cues.map(\.startTime) == [0, 3] && written.cues.map(\.endTime) == [2, 6], "写回不能改时间戳")
        let newest = reloaded.item(with: f.id)!.subtitleFilePath!
        try check(newest != f.active.path && newest != f.initial.path, "每次润色写全新的文件")
        try check(f.store().item(with: f.id)?.subtitleFilePath == newest, "成功返回时活动版本已落盘")
        do {
            _ = try reloaded.writeSubtitleTranslations([.init(index: 0, translation: "只有一句")], revision: written.revision, for: f.id)
            throw Failed(message: "部分写入被错误接受")
        } catch let failure as SubtitleVersionStore.Failure {
            try check(failure.code == "invalid_arguments", "部分写入整批拒绝")
        }
        do {
            _ = try reloaded.writeSubtitleTranslations([.init(index: 0, translation: "甲"), .init(index: 1, translation: "乙")], revision: before.revision, for: f.id)
            throw Failed(message: "旧修订被错误接受")
        } catch let failure as SubtitleVersionStore.Failure {
            try check(failure.code == "subtitles_changed", "旧修订必须拒绝")
        }
        _ = try reloaded.restoreInitialTranslation(for: f.id)
        try check(reloaded.item(with: f.id)?.subtitleFilePath == f.initial.path && reloaded.item(with: f.id)?.translationSource == "youtube_auto", "退回最初下载版本及其来源")
        try check(FileManager.default.fileExists(atPath: newest), "退回保留润色版本")
        try check(Data(contentsOf: f.initial) == original && Data(contentsOf: f.active) == polished, "写回和退回都不改首次字幕及旧润色文件")
        let old = try fixture(versioned: false); defer { old.clean() }
        let oldStore = old.store()
        try check(oldStore.items.count == 1 && oldStore.item(with: old.id)?.initialSubtitlePath == nil, "旧队列缺新字段仍可读")
        try check(oldStore.flushPendingSaves() && old.store().items.count == 1, "旧队列可保存重读")
        for state in ["transcribing", "translating"] {
            let interrupted = try fixture(state: state); defer { interrupted.clean() }
            let restarted = interrupted.store()
            try check(restarted.item(with: interrupted.id)?.transcriptionState == "queued", "中断的转写或翻译下次启动重新排队")
        }
        try checkInitialDisplayReuse()
        print("subtitle_version_storage_check=passed: 活动版本不回退，整轨写回、修订冲突、部分拒绝、退回保留历史、旧队列与中断排队均通过")
    }

    @MainActor static func checkDownloadedTracksRescan() async throws {
        let f = try fixture(versioned: false); defer { f.clean() }
        try FileManager.default.removeItem(at: f.initial)
        try FileManager.default.removeItem(at: f.active)
        var originals: [URL: Data] = [:]
        for language in ["en", "en-orig", "zh-Hans-en", "zh-Hant-en"] {
            let path = f.media.appendingPathComponent("\(f.id.uuidString).\(language).srt")
            let text = language.hasPrefix("en") ? "Welcome." : "欢迎。"
            let bytes = Data("1\n00:00:00,000 --> 00:00:02,000\n\(text)\n".utf8)
            try bytes.write(to: path); originals[path] = bytes
        }
        let movie = f.media.appendingPathComponent("\(f.id.uuidString).mp4")
        try Data("fixture media".utf8).write(to: movie)
        var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as! [[String: Any]]
        rows[0]["subtitleFilePath"] = f.media.appendingPathComponent("\(f.id.uuidString).zh-Hans-en.srt").path
        rows[0]["localFilePath"] = movie.path; rows[0]["urlString"] = "https://www.youtube.com/watch?v=Tracks00001"
        try JSONSerialization.data(withJSONObject: rows).write(to: f.file)
        let initial = f.store(); initial.startLocalTranscriptionQueue(); initial.stopLocalTranscriptionQueue()
        let active = initial.item(with: f.id)!.subtitleFilePath!
        let revision = try initial.subtitleSnapshot(for: f.id).revision
        try check(initial.item(with: f.id)?.translationSource == "youtube_auto", "构造四条下载轨先登记机器来源")
        try check(initial.flushPendingSaves(), "登记下载轨保存")
        for opening in 1...3 {
            let reopened = f.store()
            let picked: String = await withCheckedContinuation { c in reopened.rescanLocalSubtitle(for: f.id) { c.resume(returning: $0) } }
            try check(picked == active && reopened.item(with: f.id)?.translationSource == "youtube_auto", "第\(opening)次重开不能把未选下载轨当外置人工字幕")
            try check(try reopened.subtitleSnapshot(for: f.id).revision == revision, "重开下载多轨不能改变revision")
            try check(reopened.flushPendingSaves(), "重扫结果保存")
        }
        for (path, bytes) in originals { try check(try Data(contentsOf: path) == bytes, "重扫不改下载字幕原件") }
        var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as! [[String: Any]]
        try check((saved[0]["knownSubtitlePaths"] as? [String])?.count == 4, "四条原下载轨的清单持久化")
        saved[0].removeValue(forKey: "knownSubtitlePaths")
        try JSONSerialization.data(withJSONObject: saved).write(to: f.file)
        let legacy = f.store()
        let legacyPath: String = await withCheckedContinuation { c in legacy.rescanLocalSubtitle(for: f.id) { c.resume(returning: $0) } }
        try check(legacyPath == active && legacy.item(with: f.id)?.translationSource == "youtube_auto", "升级前已登记但没有清单的多轨条目也不能回退")
        try check(try legacy.subtitleSnapshot(for: f.id).revision == revision, "补旧清单不改变revision")
        print("download_tracks_rescan=passed：四轨登记、连开三次路径/来源/revision不变，下载原件不改")
    }

    @MainActor static func checkInitialDisplayReuse() throws {
        let f = try fixture(versioned: false); defer { f.clean() }
        let en = f.media.appendingPathComponent("\(f.id.uuidString).en.srt")
        try Data("1\n00:00:00,000 --> 00:00:02,000\nWelcome.\n".utf8).write(to: en)
        try Data("1\n00:00:00,000 --> 00:00:02,000\n欢迎。\n".utf8).write(to: f.initial)
        let original = try Data(contentsOf: en), initial = try Data(contentsOf: f.initial)
        let display = f.media.appendingPathComponent("\(f.id.uuidString).initial-display-seed.vtt")
        try SubtitleVersionStore.write([VideoSubtitleCue(startTime: 0, endTime: 2, text: "Welcome.\n欢迎。", isSentenceBlock: true)], to: display)
        var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as! [[String: Any]]
        rows[0]["originalSubtitlePath"] = en.path; rows[0]["initialSubtitlePath"] = f.initial.path
        rows[0]["subtitleFilePath"] = display.path; rows[0]["translationSource"] = "youtube_auto"; rows[0]["initialTranslationSource"] = "youtube_auto"
        try JSONSerialization.data(withJSONObject: rows).write(to: f.file)
        func displays() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: f.media.path).filter { $0.contains(".initial-display-") }.sorted() }
        let store = f.store(), before = try displays(), revision = try store.subtitleSnapshot(for: f.id).revision
        for _ in 0..<3 {
            let result = try store.restoreInitialTranslation(for: f.id)
            try check(try displays() == before && store.item(with: f.id)?.subtitleFilePath == display.path, "已经是初译不能反复新建显示文件")
            try check(result.revision == revision, "重复退回初译没有实际变更，不改变revision")
        }
        for _ in 0..<2 {
            let revision = try store.subtitleSnapshot(for: f.id).revision
            _ = try store.writeSubtitleTranslations([.init(index: 0, translation: "润色后的欢迎。")], revision: revision, for: f.id)
            let active = store.item(with: f.id)!.subtitleFilePath!
            _ = try store.restoreInitialTranslation(for: f.id)
            try check(try displays() == before && store.item(with: f.id)?.subtitleFilePath == display.path, "分轨反复润色和退回复用同一份首次显示文件")
            try check(FileManager.default.fileExists(atPath: active), "退回仍保留每次润色历史")
        }
        let reopened = f.store(); _ = try reopened.restoreInitialTranslation(for: f.id)
        try check(try displays() == before && Data(contentsOf: en) == original && Data(contentsOf: f.initial) == initial, "重开后仍复用，原文与原下载初译字节不变")
        print("initial_display_reuse=passed：初译重复退回幂等、分轨反复润色复用、重开不增文件且保留历史")
    }

    @MainActor static func checkExternalRescan() async throws {
        let f = try fixture(versioned: false); defer { f.clean() }
        let en = f.media.appendingPathComponent("\(f.id.uuidString).en.srt")
        let original = Data("1\n00:00:00,000 --> 00:00:02,000\nWelcome.\n".utf8)
        try original.write(to: en)
        try FileManager.default.removeItem(at: f.initial)
        let movie = f.media.appendingPathComponent("\(f.id.uuidString).mp4")
        try Data("fixture media".utf8).write(to: movie)
        var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as! [[String: Any]]
        rows[0]["subtitleFilePath"] = en.path; rows[0]["localFilePath"] = movie.path
        try JSONSerialization.data(withJSONObject: rows).write(to: f.file)
        let store = f.store(); store.startLocalTranscriptionQueue()
        defer { store.stopLocalTranscriptionQueue() }
        try check(store.item(with: f.id)?.originalSubtitlePath == en.path, "只有英文字幕在启动后登记原文")
        try Data("1\n00:00:00,000 --> 00:00:02,000\nWelcome.\n人工补充中文。\n".utf8).write(to: f.initial)
        let path: String = await withCheckedContinuation { c in store.rescanLocalSubtitle(for: f.id) { c.resume(returning: $0) } }
        try check(path == f.initial.path, "登记英文后仍须接上新外置.zh.srt")
        let updated = store.item(with: f.id)!
        try check(updated.translationSource == "author" && !updated.translationPolishable, "新外置字幕按人工登记，不得润色")
        try check(Data(contentsOf: en) == original && store.flushPendingSaves(), "保留原英文文件，人工来源真正保存")
        try check(f.store().item(with: f.id)?.translationSource == "author", "重读仍是人工来源")
        let protected = try fixture(); defer { protected.clean() }
        let protectedStore = protected.store()
        let generated = protected.media.appendingPathComponent("\(protected.id.uuidString).agent-99-new.vtt")
        try Data("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nGenerated.\n".utf8).write(to: generated)
        let unchanged: String = await withCheckedContinuation { c in protectedStore.rescanLocalSubtitle(for: protected.id) { c.resume(returning: $0) } }
        try check(unchanged == protected.active.path, "已登记初译或未登记生成版本不能抢活动版本")
        let manual = protected.media.appendingPathComponent("\(protected.id.uuidString).zh-CN.srt")
        try Data("1\n00:00:00,000 --> 00:00:02,000\n另一份人工中文。\n".utf8).write(to: manual)
        let adopted: String = await withCheckedContinuation { c in protectedStore.rescanLocalSubtitle(for: protected.id) { c.resume(returning: $0) } }
        try check(adopted == manual.path, "即使旧初译排名更高，也能发现新的外置人工字幕")
        let external = try protectedStore.subtitleSnapshot(for: protected.id)
        try check(SubtitleVersionStore.split(external.cues[0]).translation == "另一份人工中文。", "新增纯中文外置初译也须能读，不能误报版本冲突")
        print("external_rescan=passed：登记后的英文可接上外置中文，人工来源保存，初译与生成版本不抢活动路径")
    }
}
