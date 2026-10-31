import Foundation
import Testing
@testable import golos_meet

private struct DelayedHookLLM: ChatCompleter {
    let entered: IndexGate
    let release: IndexGate
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        await entered.signal(); await release.wait()
        return "{\"title\":\"Синтетическая встреча\",\"summary\":\"Проверка\",\"actionPoints\":[]}"
    }
}

@MainActor @Suite struct IndexingProductionHooksTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("index-hooks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func until(_ label: String = "indexing state", _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for \(label)")
        throw CocoaError(.fileReadUnknown)
    }

    @Test func defaultProducerHooksRunWithoutViewsAndTranscriptDoesNotWaitForLLMOrIndexing() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let entered = IndexGate(), release = IndexGate()
        let encoder = LifecycleEncoder(entered: entered, release: release)
        let candidate = LocalEmbeddingCandidate(model: .init(id: encoder.modelID, dimensions: 2), folder: nil, load: { encoder })
        let service = LocalIndexingService(store: store, meetingsRoot: root.appendingPathComponent("meetings"), inspect: { candidate })
        // The actual default process-local producer channel, but a private
        // controller/store/root. No SwiftUI view or production singleton exists.
        let indexing = KnowledgeIndexing(service: service, installer: .init(root: root.appendingPathComponent("models")), center: .default)
        defer { indexing.stop() }
        indexing.start(); indexing.start(); await service.waitUntilIdle()
        let importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
        let queue = DocumentImportQueue(importer: importer, store: store)
        let one = root.appendingPathComponent("Один.txt"), two = root.appendingPathComponent("Два.txt")
        try Data("Первый синтетический документ".utf8).write(to: one)
        try Data("Второй синтетический документ".utf8).write(to: two)
        await queue.enqueue(urls: [one, two], projectIDs: [])
        await entered.wait()
        try await until { queue.completedCount == 2 }
        #expect(try await store.documents().count == 2) // inference is still held
        await release.signal()
        try await until { try await store.embeddingJobs().filter { $0.state == .ready }.count == 2 }

        let meeting = root.appendingPathComponent("meetings/hooks-meeting")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try Data([0x52]).write(to: meeting.appendingPathComponent("mic.wav"))
        try MeetingMeta(id: "hooks-meeting", source: "synthetic", startedAt: Date(), endedAt: Date(),
                        durationSeconds: 600, status: .recording, asrModel: nil).write(to: meeting.appendingPathComponent("meta.json"))
        let llmEntered = IndexGate(), llmRelease = IndexGate()
        let pipeline = ProcessingPipeline(asrFactory: {
            ProcessingPipelineTests.StubASR(perFile: ["mic.wav": [.init(start: 1, end: 4, text: "Запуск согласован на декабрь")]])
        }, insightsGenerator: .init(client: DelayedHookLLM(entered: llmEntered, release: llmRelease), model: "synthetic-no-network"))
        let processing = Task { await pipeline.process(folder: meeting) }
        await llmEntered.wait()
        try await until { try await store.embeddingJobs().contains { $0.source.externalID == "hooks-meeting" && $0.state == .ready } }
        #expect(try MeetingMeta.decoded(Data(contentsOf: meeting.appendingPathComponent("meta.json"))).status == .summarizing)
        // Index is ready while the simulated network generation has not returned.
        await llmRelease.signal(); await processing.value
        #expect(try Data(contentsOf: meeting.appendingPathComponent("mic.wav")) == Data([0x52]))
        try MeetingStore.delete(id: "hooks-meeting", root: root.appendingPathComponent("meetings"))
        try await until { try await store.embeddingJobs().allSatisfy { $0.source.externalID != "hooks-meeting" } }
        indexing.stop(); await service.stop()
    }

    @Test func actualFileMonitorReconcilesExternalAtomicAndInPlaceTranscriptChangesWithoutUI() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let meetings = root.appendingPathComponent("meetings"), models = root.appendingPathComponent("models")
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite")), encoder = LifecycleEncoder()
        let service = LocalIndexingService(store: store, meetingsRoot: meetings, inspect: {
            .init(model: .init(id: encoder.modelID, dimensions: 2), folder: nil, load: { encoder })
        })
        let indexing = KnowledgeIndexing(service: service, installer: .init(root: models), roots: (meetings, models))
        defer { indexing.stop() }
        indexing.start()
        let folder = meetings.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("transcript.json")
        func bytes(_ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["meetingId": "external", "segments": [["start": 3, "end": 8, "text": text]]])
        }
        try bytes("Первая версия внешнего файла").write(to: file, options: .atomic)
        try await until("initial file index") { try await store.embeddingJobs().first?.state == .ready }
        let first = try #require(try await store.embeddingJobs().first)
        let timestamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try bytes("Вторая версия внешнего файла").write(to: file) // in-place write
        if let timestamp { try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path) }
        try await until("in-place rewrite with restored mtime") { try await store.embeddingJobs().contains { $0.state == .ready && $0.generation != first.generation } }
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "external")
        let stored = try await store.embeddingWindows(for: key, model: .init(id: encoder.modelID, dimensions: 2))
        #expect(stored.first?.chunk.text == "Вторая версия внешнего файла")
        #expect(stored.first?.chunk.location.startSeconds == 3)
        try Data("{malformed".utf8).write(to: file, options: .atomic)
        try await until("malformed file invalidation") { try await store.embeddingJobs().isEmpty }
        try await until("malformed file error publication") { !indexing.snapshot.sourceErrors.isEmpty }
        try FileManager.default.removeItem(at: folder)
        try await until("deleted folder reconciliation") { indexing.snapshot.sourceErrors.isEmpty }
        #expect(indexing.monitorMessage == nil)
        indexing.stop(); await service.stop()
    }

    @Test func eventPathKeepsDeletedAliasesAndFinalSymlinkInsideWatchedPrefix() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let watched = root.appendingPathComponent("meetings")
        let folder = watched.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let canonical = folder.resolvingSymlinksInPath().path
        let raw = canonical.hasPrefix("/var/") ? "/private" + canonical : canonical
        let before = LocalIndexingService.eventPath(URL(fileURLWithPath: raw))
        try FileManager.default.removeItem(at: folder)
        #expect(LocalIndexingService.eventPath(URL(fileURLWithPath: raw)) == before)
        #expect(before.hasPrefix(LocalIndexingService.eventPath(watched) + "/"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.json")
        try Data("synthetic target".utf8).write(to: target)
        let link = folder.appendingPathComponent("transcript.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(LocalIndexingService.eventPath(link).hasPrefix(LocalIndexingService.eventPath(watched) + "/"))
        #expect(LocalIndexingService.eventPath(link).hasSuffix("/external/transcript.json"))
        #expect(try Data(contentsOf: target) == Data("synthetic target".utf8))
    }
}
