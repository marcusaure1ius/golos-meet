import Foundation
import SQLite3
import Testing
@testable import golos_meet

@MainActor @Suite struct SQLiteFixtureLifecycleTests {
    private func makeRoot(_ scope: SQLiteFixtureScope) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scope.register(root: root)
        return root
    }
    private func delayedWrite(root: URL, scope: SQLiteFixtureScope, entered: IndexGate, release: IndexGate) async throws -> Task<Void, Error> {
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        scope.register(store: store)
        _ = try await store.createProject(name: "Before release")
        return Task {
            await entered.signal(); await release.wait()
            _ = try await store.createProject(name: "Actual late write")
            #expect(try await store.snapshot().projects.count == 2)
            scope.note("late-write-finished")
        }
    }
    @Test func cleanupWaitsForLateTaskWriteAndNativeCloseBeforeUnlink() async throws {
        let scope = SQLiteFixtureScope(), entered = IndexGate(), release = IndexGate()
        try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
            let root = try makeRoot(scope)
            let pending = try await delayedWrite(root: root, scope: scope, entered: entered, release: release)
            await entered.wait()
            let cleanup = Task { try await scope.finish() }
            while !scope.trace.contains(where: { $0["stage"] == "body-finished" }) { await Task.yield() }
            #expect(FileManager.default.fileExists(atPath: root.path))
            #expect(!scope.trace.contains { $0["stage"] == "closed" })
            await release.signal()
            try await pending.value; try await cleanup.value
            #expect(!FileManager.default.fileExists(atPath: root.path))
            let stages = scope.trace.compactMap { $0["stage"] }
            #expect(try #require(stages.firstIndex(of: "late-write-finished")) < #require(stages.firstIndex(of: "closed")))
            #expect(try #require(stages.firstIndex(of: "closed")) < #require(stages.firstIndex(of: "root-removed")))
        }
    }
    private enum BodyFailure: Error { case expected }
    private func failingBody(root: URL, scope: SQLiteFixtureScope) async throws {
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        scope.register(store: store)
        _ = try await store.createProject(name: "Synthetic throw path")
        throw BodyFailure.expected
    }
    @Test func throwingBodyReleasesStoreAndPreservesOriginalFailure() async throws {
        let scope = SQLiteFixtureScope()
        let root = try makeRoot(scope)
        try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
            let body: Result<Void, Error>
            do { try await failingBody(root: root, scope: scope); body = .success(()) }
            catch { body = .failure(error) }
            try await scope.finish()
            #expect(!FileManager.default.fileExists(atPath: root.path))
            #expect(throws: BodyFailure.expected) { try body.get() }
        }
    }
}


nonisolated private final class LifecycleEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProjectDatabase.LifecycleEvent] = []
    func append(_ value: ProjectDatabase.LifecycleEvent) { lock.withLock { values.append(value) } }
    var failures: [ProjectDatabase.Diagnostic] {
        lock.withLock { values.compactMap { if case .failure(let d) = $0 { d } else { nil } } }
    }
    var closes: Int {
        lock.withLock { values.filter { if case .closed(_, SQLITE_OK) = $0 { true } else { false } }.count }
    }
}

@MainActor extension SQLiteFixtureLifecycleTests {
    private func failInForeignTaskContext(root: URL, owner: LifecycleEvents, foreign: LifecycleEvents) throws {
        let db = try ProjectDatabase.$lifecycleObserver.withValue({ owner.append($0) }) {
            try ProjectDatabase(url: root.appendingPathComponent("owner.sqlite"))
        }
        try db.execute("CREATE TABLE sentinel(value INTEGER)")
        ProjectDatabase.$lifecycleObserver.withValue({ foreign.append($0) }) {
            // Actual SQLite prepare error; only the creating observer owns it.
            #expect(throws: (any Error).self) { try db.execute("SELECT * FROM missing_table") }
        }
    }
    @Test func connectionObserverOwnsFailureEvenWhenCallerHasAnotherTaskContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("observer-owner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = LifecycleEvents(), foreign = LifecycleEvents()
        try failInForeignTaskContext(root: root, owner: owner, foreign: foreign)
        #expect(owner.failures.count == 1 && owner.failures.first?.result == SQLITE_ERROR)
        #expect(owner.failures.first?.phase == .prepare)
        #expect(owner.closes == 1 && foreign.closes == 0 && foreign.failures.isEmpty)
    }
}
