import Foundation
import Testing
@testable import golos_meet

actor IndexGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
}

/// Tiny vectors are explicit lifecycle fixtures, not semantic inference.
actor LifecycleEncoder: LocalPassageEmbedding {
    nonisolated let modelID: String
    nonisolated let dimensions = 2
    private var calls: [String] = []
    private let entered: IndexGate?
    private let release: IndexGate?
    private let queryEntered: IndexGate?
    private let queryRelease: IndexGate?
    private var fail = false
    init(id: String = "synthetic-queue-A", entered: IndexGate? = nil, release: IndexGate? = nil,
         queryEntered: IndexGate? = nil, queryRelease: IndexGate? = nil) {
        modelID = id; self.entered = entered; self.release = release
        self.queryEntered = queryEntered; self.queryRelease = queryRelease
    }
    func passageWindows(_ text: String) async throws -> [EmbeddedPassageWindow] {
        calls.append(text)
        if calls.count == 1 { await entered?.signal(); await release?.wait() }
        try Task.checkCancellation()
        if fail { throw EmbeddingIndexError.invalidVectors }
        return [.init(tokenStart: 0, tokenCount: 3, vector: try KnowledgeVector(modelID: modelID, values: [1, 2]))]
    }
    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [KnowledgeVector] {
        await queryEntered?.signal(); await queryRelease?.wait()
        return try texts.map { _ in try KnowledgeVector(modelID: modelID, values: [1, 2]) }
    }
    func texts() -> [String] { calls }
    func setFailure(_ value: Bool) { fail = value }
}

actor CandidateSource {
    var candidate: LocalEmbeddingCandidate?
    private var loads: [String: Int] = [:]
    func set(_ candidate: LocalEmbeddingCandidate?) { self.candidate = candidate }
    func inspect() -> LocalEmbeddingCandidate? { candidate }
    func loaded(_ id: String) { loads[id, default: 0] += 1 }
    func count(_ id: String) -> Int { loads[id, default: 0] }
}

@MainActor @Suite struct LocalIndexingServiceTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("index-service-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func meeting(_ root: URL, id: String, text: String) throws {
        let folder = root.appendingPathComponent("meetings/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["meetingId": id, "segments": [["start": 1, "end": 2, "text": text]]])
            .write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
    }
    private func candidate(_ encoder: LifecycleEncoder, source: CandidateSource,
                           entered: IndexGate? = nil, release: IndexGate? = nil) -> LocalEmbeddingCandidate {
        .init(model: .init(id: encoder.modelID, dimensions: 2), folder: nil, load: {
            await source.loaded(encoder.modelID); await entered?.signal(); await release?.wait()
            return encoder
        })
    }
    private func service(_ root: URL, store: ProjectStore, source: CandidateSource) -> LocalIndexingService {
        .init(store: store, meetingsRoot: root.appendingPathComponent("meetings"), inspect: { await source.inspect() })
    }

    @Test func missingModelDoesNotBlockImportAndActivationIndexesWithoutReimportOrDuplicateLoad() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let source = CandidateSource(), encoder = LifecycleEncoder()
        let service = service(root, store: store, source: source)
        await service.start(); await service.start()
        let file = root.appendingPathComponent("План.txt")
        try Data("Запуск проекта в декабре".utf8).write(to: file)
        _ = try await DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
            .importFile(id: UUID(), url: file, projectIDs: []) { _ in }
        await service.changed(); await service.waitUntilIdle()
        #expect(try await store.documents().count == 1)
        #expect(try await store.embeddingJobs().first?.state == .waitingForModel)
        #expect(await service.snapshot().modelState == .missing)
        await source.set(candidate(encoder, source: source)); await service.modelChanged()
        await service.waitUntilIdle()
        let ready = try #require(try await store.embeddingJobs().first)
        #expect(ready.state == .ready)
        #expect(await source.count(encoder.modelID) == 1)
        await service.modelChanged(); await service.start(); await service.waitUntilIdle()
        #expect(try await store.embeddingJobs().first?.generation == ready.generation)
        #expect(await source.count(encoder.modelID) == 1)
        await service.stop()
    }

    @Test func sourceSupersessionUsesFreshBytesAndRoundRobinDoesNotStarveAnotherSource() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try meeting(root, id: "a", text: "Альфа первая версия")
        try meeting(root, id: "b", text: "Бета стабильная версия")
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let entered = IndexGate(), release = IndexGate(), source = CandidateSource()
        let encoder = LifecycleEncoder(entered: entered, release: release)
        await source.set(candidate(encoder, source: source))
        let service = service(root, store: store, source: source)
        await service.start(); await entered.wait()
        try meeting(root, id: "a", text: "Альфа новая версия")
        await service.changed(source: .init(kind: .meeting, externalID: "a"))
        await release.signal(); await service.waitUntilIdle()
        let calls = await encoder.texts()
        #expect(calls.count == 3)
        #expect(calls[1].contains("Бета") && calls[2].contains("новая"))
        #expect(try await store.embeddingJobs().allSatisfy { $0.state == .ready })
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "a")
        let windows = try await store.embeddingWindows(for: key, model: .init(id: encoder.modelID, dimensions: 2))
        #expect(windows.first?.chunk.text == "Альфа новая версия")
        await service.stop()
    }

    @Test func lateModelLoaderAndLateQueryCannotUndoModelABAAndSameIDKeepsReadyCache() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try meeting(root, id: "a", text: "Стабильный источник")
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let source = CandidateSource(), queryEntered = IndexGate(), queryRelease = IndexGate()
        let a = LifecycleEncoder(queryEntered: queryEntered, queryRelease: queryRelease)
        await source.set(candidate(a, source: source))
        let service = service(root, store: store, source: source)
        await service.start(); await service.waitUntilIdle()
        let original = try #require(try await store.embeddingJobs().first)
        let query = Task { try await service.embedQuery("Запрос к A") }
        await queryEntered.wait()
        let bEntered = IndexGate(), bRelease = IndexGate(), b = LifecycleEncoder(id: "synthetic-queue-B")
        await source.set(candidate(b, source: source, entered: bEntered, release: bRelease))
        await service.modelChanged(); await bEntered.wait()
        await source.set(candidate(a, source: source)); await service.modelChanged()
        await bRelease.signal(); await service.waitUntilIdle()
        await queryRelease.signal()
        await #expect(throws: LocalIndexingError.self) { try await query.value }
        #expect(try await store.embeddingJobs().first?.generation == original.generation)
        let aLoads = await source.count(a.modelID), bLoads = await source.count(b.modelID)
        #expect(aLoads == 1 && bLoads == 1)
        #expect(try await store.embeddingWindows(for: original.source, model: .init(id: a.modelID, dimensions: 2)).count == 1)
        await service.stop()
    }

    @Test func cancelRetryFailureAndRestartRecoverOnlyInterruptedAttempt() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try meeting(root, id: "a", text: "Синтетический источник")
        let url = root.appendingPathComponent("knowledge.sqlite"), source = CandidateSource()
        let store = ProjectStore(url: url), entered = IndexGate(), release = IndexGate()
        let encoder = LifecycleEncoder(entered: entered, release: release)
        await source.set(candidate(encoder, source: source))
        let service = service(root, store: store, source: source)
        await service.start(); await entered.wait()
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "a")
        await service.cancel(key); await release.signal(); await service.waitUntilIdle()
        #expect(try await store.embeddingJobs().first?.state == .cancelled)
        await encoder.setFailure(true); await service.retry(key); await service.waitUntilIdle()
        #expect(try await store.embeddingJobs().first?.state == .failed)
        await service.stop()
        await encoder.setFailure(false)
        try await store.retryEmbeddingJob(key)
        let crashed = try #require(try await store.claimEmbeddingJob())
        let restartedStore = ProjectStore(url: url)
        let restarted = self.service(root, store: restartedStore, source: source)
        await restarted.start(); await restarted.start(); await restarted.waitUntilIdle()
        #expect(try await restartedStore.embeddingJobs().first?.state == .ready)
        #expect(try await restartedStore.embeddingJobs().first?.generation != crashed.job.generation)
        await restarted.stop()
    }
}
