import Foundation
import Testing
@testable import golos_meet

private actor NativeRuntimeLoads {
    private var loads = 0
    private var folders: Set<URL> = []
    func inspected(_ folder: URL) { folders.insert(folder) }
    func loaded() { loads += 1 }
    func count() -> Int { loads }
    func saw(_ folder: URL) -> Bool { folders.contains(folder) }
}

/// Actual installer, local runtime, queue, SQLite, process-local import event
/// and OS file monitor. Only pinned public weights and synthetic temp sources.
@MainActor @Suite(.serialized) struct LocalIndexingNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLOS_MEET_E5_FOLDER"] != nil))
    func nativeQueueResumesAfterInstallationWatchesTranscriptAndKeepsSameModelCache() async throws {
        let weights = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GOLOS_MEET_E5_FOLDER"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-index-queue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = root.appendingPathComponent("meetings"), models = root.appendingPathComponent("models")
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let installer = EmbeddingModelInstaller(root: models), counter = NativeRuntimeLoads()
        let service = LocalIndexingService(store: store, meetingsRoot: meetings, inspect: {
            guard let candidate = try await LocalEmbeddingCandidate.installed(using: installer), let folder = candidate.folder else { return nil }
            await counter.inspected(folder)
            return .init(model: candidate.model, folder: folder, load: {
                await counter.loaded()
                return try await candidate.load()
            })
        })
        let center = NotificationCenter()
        let indexing = KnowledgeIndexing(service: service, installer: installer, roots: (meetings, models), center: center)
        defer { indexing.stop() }
        indexing.start(); indexing.start() // two windows share one composition
        let source = root.appendingPathComponent("Проект.txt")
        let original = Data(("Запуск согласован на декабрь. " + String(repeating: "漢字🧪 ", count: 450)).utf8)
        try original.write(to: source)
        let queue = DocumentImportQueue(importer: .init(store: store, root: root.appendingPathComponent("copies")), store: store,
            onImported: { KnowledgeIndexEvents.post(.document($0), center: center) })
        await queue.enqueue(urls: [source], projectIDs: [])
        let meeting = meetings.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let file = meeting.appendingPathComponent("transcript.json")
        func transcript(_ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["meetingId": "native", "segments": [["start": 5.5, "end": 14.25, "text": text]]])
        }
        try transcript("Анна согласовала запуск на декабрь.").write(to: file, options: .atomic)
        try await until { queue.completedCount == 1 && indexing.snapshot.modelState == .missing && indexing.snapshot.jobs.count == 2 }
        #expect(await counter.count() == 0)
        // This is the user's local-folder path, not an implicit model download.
        _ = try await installer.install(from: weights) { _ in }
        try await until { try await store.embeddingJobs().filter { $0.state == .ready }.count == 2 }
        #expect(await counter.count() == 1)
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "native")
        let previous = try #require(try await store.embeddingJobs().first { $0.source == key })
        try transcript("Борис перенёс запуск на январь.").write(to: file, options: .atomic)
        try await until { try await store.embeddingJobs().contains { $0.source == key && $0.state == .ready && $0.generation != previous.generation } }
        let stored = try await store.embeddingWindows(for: key, model: .e5Small)
        #expect(stored.first?.chunk.text.contains("Борис") == true)
        #expect(stored.first?.chunk.location.startSeconds == 5.5)
        #expect(stored.allSatisfy { $0.vector.values.count == 384 && $0.vector.modelID == EmbeddingIndexModel.e5Small.id })
        let ready = try await store.embeddingJobs()
        let replacement = try await installer.install(from: weights) { _ in }
        try await until {
            let saw = await counter.saw(replacement), state = await service.snapshot()
            return saw && state.modelState == .ready
        }
        #expect(await counter.count() == 1) // installed copies changed, modelID did not
        #expect(try await store.embeddingJobs().map(\.generation) == ready.map(\.generation))
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: meeting.path) == ["transcript.json"])
        #expect(indexing.monitorMessage == nil)
        indexing.stop(); await service.stop()
        let restarted = LocalIndexingService(store: ProjectStore(url: root.appendingPathComponent("knowledge.sqlite")), meetingsRoot: meetings,
            inspect: { try await LocalEmbeddingCandidate.installed(using: installer) })
        await restarted.start(); await restarted.waitUntilIdle()
        #expect(try await store.embeddingJobs().map(\.generation) == ready.map(\.generation))
        await restarted.stop()
    }

    private func until(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Native queue did not reach the required state")
        throw CocoaError(.fileReadUnknown)
    }
}
