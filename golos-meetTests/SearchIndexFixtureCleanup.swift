import Foundation
import Testing
@testable import golos_meet

/// Test-owned resources only. Release noncooperative gates before waiting for
/// workers; weak references never extend the lifetime needed for native unlink.
@MainActor final class SearchIndexFixtureCleanup {
    private struct WeakIndexer { weak var value: LocalIndexingService? }
    private struct WeakSource { weak var value: CandidateSource? }
    private struct WeakModel { weak var value: KnowledgeSearchModel? }
    private weak var scope: SQLiteFixtureScope?
    private var gates: [IndexGate] = []
    private var indexers: [WeakIndexer] = []
    private var sources: [WeakSource] = []
    private var models: [WeakModel] = []
    private var cancellations: [() -> Void] = []
    private var joins: [() async -> Void] = []

    init(scope: SQLiteFixtureScope) {
        self.scope = scope
        scope.onFinish { [self] in await finish() }
    }
    func own(_ gate: IndexGate) { gates.append(gate) }
    func own(_ store: ProjectStore) { scope?.register(store: store) }
    func own(_ model: KnowledgeSearchModel) { models.append(.init(value: model)) }
    func own<Value: Sendable>(_ task: Task<Value, Error>) {
        cancellations.append { task.cancel() }
        // Original tests still assert the typed result. This is a join, and
        // neither changes that result nor acknowledges native SQLite failures.
        joins.append { _ = await task.result }
    }
    func track(_ indexer: LocalIndexingService, store: ProjectStore, source: CandidateSource? = nil) {
        own(store); indexers.append(.init(value: indexer))
        if let source { sources.append(.init(value: source)) }
    }
    func finish() async {
        scope?.note("search-index-cleanup-enter")
        for reference in models { reference.value?.clear() }
        let cancels = cancellations; cancellations = []
        for cancel in cancels { cancel() }
        let releases = gates; gates = []
        for gate in releases { await gate.signal() }
        scope?.note("search-index-gates-released")
        for reference in indexers {
            if let indexer = reference.value {
                scope?.note("search-index-stop-enter")
                await indexer.stop(); await indexer.waitUntilIdle()
                scope?.note("search-index-stop-returned")
            }
        }
        let operations = joins; joins = []
        for join in operations { await join(); scope?.note("search-index-operation-joined") }
        // CandidateSource holds a load callback which captures CandidateSource.
        // Break that real fake-runtime cycle after its worker has stopped.
        for reference in sources { await reference.value?.set(nil) }
        models = []; indexers = []; sources = []
        scope?.note("search-index-resources-finished")
    }
}

@MainActor final class SearchIndexFixtureWitness {
    weak var store: ProjectStore?
    weak var indexer: LocalIndexingService?
    weak var search: KnowledgeSearchService?
    weak var model: KnowledgeSearchModel?
    weak var source: CandidateSource?
    weak var encoder: HeldIndexFixtureEncoder?
    var root: URL?
    var resources: SearchIndexFixtureCleanup?
}

/// Intentionally ignores cancellation until after an actual late SQLite write.
actor HeldIndexFixtureEncoder: LocalPassageEmbedding {
    nonisolated let modelID = "synthetic-held-index"
    nonisolated let dimensions = 2
    private let store: ProjectStore
    private let root: URL
    private let scope: SQLiteFixtureScope
    private let entered: IndexGate
    private let release: IndexGate
    private let tail: IndexGate
    init(store: ProjectStore, root: URL, scope: SQLiteFixtureScope, entered: IndexGate, release: IndexGate, tail: IndexGate) {
        self.store = store; self.root = root; self.scope = scope
        self.entered = entered; self.release = release; self.tail = tail
    }
    func embed(_ texts: [String], purpose: EmbeddingPurpose) throws -> [KnowledgeVector] {
        try texts.map { _ in try KnowledgeVector(modelID: modelID, values: [1, 2]) }
    }
    func passageWindows(_ text: String) async throws -> [EmbeddedPassageWindow] {
        await entered.signal(); await release.wait()
        scope.note("search-index-late-write-enter")
        #expect(FileManager.default.fileExists(atPath: root.path))
        _ = try await store.createProject(name: "Synthetic held index late write")
        #expect(try await store.snapshot().projects.count == 1)
        scope.note("search-index-late-write-finished")
        await tail.wait()
        scope.note("index-held-passage-returned")
        return [.init(tokenStart: 0, tokenCount: 3, vector: try embed([text], purpose: .passage)[0])]
    }
}
