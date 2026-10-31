import Foundation
import SQLite3
import Testing
@testable import golos_meet

/// Only fixed event labels, clocks, numeric codes and sanitized DB diagnostics.
private nonisolated final class MigrationTrace: @unchecked Sendable {
    struct Event: Codable {
        let name: String
        let milliseconds: Double
        let result: Int32?
        let extended: Int32?
        let scheduledMilliseconds: Double?
        let diagnostic: ProjectDatabase.Diagnostic?
        let connection: UUID?
    }
    let scenario = UUID()
    let version: Int
    private let started = ProcessInfo.processInfo.systemUptime
    private let mutex = NSLock()
    private var entries: [Event] = []
    init(version: Int) { self.version = version }
    var milliseconds: Double { (ProcessInfo.processInfo.systemUptime - started) * 1000 }
    func record(_ name: String, result: Int32? = nil, extended: Int32? = nil,
                scheduledMilliseconds: Double? = nil, error: (any Error)? = nil, connection: UUID? = nil) {
        let diagnostic: ProjectDatabase.Diagnostic?
        if let error = error as? ProjectStoreError, case .database(let message) = error {
            diagnostic = try? JSONDecoder().decode(ProjectDatabase.Diagnostic.self, from: Data(message.utf8))
        } else { diagnostic = nil }
        let entry = Event(name: name, milliseconds: milliseconds, result: result,
                          extended: extended, scheduledMilliseconds: scheduledMilliseconds, diagnostic: diagnostic, connection: connection)
        mutex.lock(); entries.append(entry); mutex.unlock()
        let data = try! JSONEncoder().encode(entry)
        print("SQLITE_MIGRATION_FIXTURE scenario=\(scenario) version=\(version) \(String(decoding: data, as: UTF8.self))")
    }
    var events: [Event] { mutex.lock(); defer { mutex.unlock() }; return entries }
    var summary: String {
        let data = try! JSONEncoder().encode(events)
        return "scenario=\(scenario) version=\(version) " + String(decoding: data, as: UTF8.self)
    }
}

/// A dedicated Thread releases the real reserved lock. It does not share the
/// Swift cooperative executor or the global Dispatch queue with blocking SQLite.
private nonisolated final class MigrationReservedLock: @unchecked Sendable {
    struct Release: Sendable { let commit: Int32; let extended: Int32; let close: Int32 }
    private let handle: OpaquePointer
    private let trace: MigrationTrace
    private let mutex = NSLock()
    private var scheduled = false
    private var completed: Release?
    private var waiters: [CheckedContinuation<Release, Never>] = []

    init(url: URL, trace: MigrationTrace) throws {
        self.trace = trace
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw CocoaError(.fileReadUnknown)
        }
        let result = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        guard result == SQLITE_OK else { sqlite3_close(db); throw CocoaError(.fileWriteUnknown) }
        handle = db
        trace.record("acquire", result: result, extended: sqlite3_extended_errcode(db))
    }
    deinit {
        if completed == nil { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
    }
    func releaseAfterDelay(_ seconds: TimeInterval = 0.5) {
        mutex.lock(); precondition(!scheduled); scheduled = true; mutex.unlock()
        trace.record("schedule", scheduledMilliseconds: trace.milliseconds + seconds * 1000)
        let thread = Thread { [self] in
            Thread.sleep(forTimeInterval: seconds)
            trace.record("release-start")
            let result = sqlite3_exec(handle, "COMMIT", nil, nil, nil)
            let extended = sqlite3_extended_errcode(handle)
            trace.record("commit-result", result: result, extended: extended)
            if result != SQLITE_OK {
                trace.record("cleanup-rollback", result: sqlite3_exec(handle, "ROLLBACK", nil, nil, nil))
            }
            let close = sqlite3_close(handle)
            if close != SQLITE_OK { sqlite3_close_v2(handle) }
            trace.record("close-result", result: close)
            let outcome = Release(commit: result, extended: extended, close: close)
            mutex.lock(); completed = outcome; let pending = waiters; waiters.removeAll(); mutex.unlock()
            for waiter in pending { waiter.resume(returning: outcome) }
        }
        thread.name = "golos-migration-fixture-release"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
    func waitForRelease() async -> Release {
        await withCheckedContinuation { continuation in
            mutex.lock()
            if let completed { mutex.unlock(); continuation.resume(returning: completed) }
            else { waiters.append(continuation); mutex.unlock() }
        }
    }
}

private nonisolated enum MigrationRace {
    enum ReleasePolicy { case afterSQLiteEntries, prematureNegativeControl }

    /// Signals only from SQLite's statement callback, never from Task/actor entry.
    private nonisolated final class Entries: @unchecked Sendable {
        private let mutex = NSLock()
        private let expected: Set<String>
        private var connections: [String: UUID] = [:]
        private let ready = DispatchSemaphore(value: 0)
        private let mayStep = DispatchSemaphore(value: 0)
        private let trace: MigrationTrace
        init(expected: Set<String>, trace: MigrationTrace) { self.expected = expected; self.trace = trace }
        func observe(_ label: String, connection: UUID) {
            mutex.lock()
            guard expected.contains(label), connections[label] == nil else { mutex.unlock(); return }
            // Record before signaling: the release thread cannot race ahead of evidence.
            trace.record(label + "-sqlite-begin", connection: connection)
            connections[label] = connection
            let complete = Set(connections.keys) == expected && Set(connections.values).count == expected.count
            mutex.unlock()
            if complete {
                ready.signal()
                for _ in expected { mayStep.signal() }
            }
            // SQLITE_TRACE_STMT runs before the statement's busy handler. Hold
            // the first connection here until its peer has really entered
            // SQLite, so executor scheduling cannot consume its busy_timeout.
            if mayStep.wait(timeout: .now() + 5) != .success {
                trace.record(label + "-sqlite-entry-barrier-timeout", connection: connection)
            }
        }
        func waitAndRelease(_ lock: MigrationReservedLock) async -> Bool {
            await withCheckedContinuation { continuation in
                let watchdog = Thread { [self] in
                    let entered = ready.wait(timeout: .now() + 5) == .success
                    if !entered { trace.record("sqlite-entry-timeout") }
                    // Schedule release on this thread BEFORE resuming Swift.
                    // A saturated cooperative executor must not prolong the
                    // reserved lock beyond the production busy timeout.
                    lock.releaseAfterDelay(entered ? 0.5 : 0)
                    continuation.resume(returning: entered)
                }
                watchdog.name = "golos-migration-fixture-sqlite-watchdog"
                watchdog.qualityOfService = .userInitiated
                watchdog.start()
            }
        }
    }

    /// Both distinct connections must have begun SQLite statements while the real
    /// reserved lock was held. Successful snapshots or Task markers are insufficient.
    static func hasContentionEvidence(_ trace: MigrationTrace, expected: Set<String> = ["first", "second"]) -> Bool {
        let events = trace.events
        guard !events.contains(where: { $0.name.contains("timeout") }),
              let acquired = events.first(where: { $0.name == "acquire" }), acquired.result == SQLITE_OK,
              let release = events.first(where: { $0.name == "release-start" }) else { return false }
        let entries = expected.compactMap { label in events.first { $0.name == label + "-sqlite-begin" } }
        return entries.count == expected.count && Set(entries.compactMap(\.connection)).count == expected.count
            && entries.allSatisfy { acquired.milliseconds < $0.milliseconds && $0.milliseconds < release.milliseconds }
    }

    private static func capture(_ label: String, trace: MigrationTrace, entries: Entries,
                        work: @Sendable () async throws -> ProjectSnapshot) async -> Result<ProjectSnapshot, any Error> {
        trace.record(label + "-task-start")
        do {
            let value = try await ProjectDatabase.$beginObserver.withValue({ connection in
                entries.observe(label, connection: connection)
            }) { try await work() }
            trace.record(label + "-success")
            return .success(value)
        } catch { trace.record(label + "-failure", error: error); return .failure(error) }
    }
    static func run(lock: MigrationReservedLock, trace: MigrationTrace,
                    expected: Set<String> = ["first", "second"], policy: ReleasePolicy = .afterSQLiteEntries,
                    first: @escaping @Sendable () async throws -> ProjectSnapshot,
                    second: @escaping @Sendable () async throws -> ProjectSnapshot) async -> (Result<ProjectSnapshot, any Error>, Result<ProjectSnapshot, any Error>) {
        let entries = Entries(expected: expected, trace: trace)
        let one = Task.detached { await capture("first", trace: trace, entries: entries, work: first) }
        let two = Task.detached { await capture("second", trace: trace, entries: entries, work: second) }
        switch policy {
        case .afterSQLiteEntries:
            let entered = await entries.waitAndRelease(lock)
            // On timeout, release immediately and STILL join both children before teardown.
            #expect(entered, Comment(rawValue: trace.summary))
        case .prematureNegativeControl:
            // Reproduce the old false positive: release before delayed snapshot calls.
            lock.releaseAfterDelay()
        }
        let firstResult = await one.value
        let secondResult = await two.value
        let release = await lock.waitForRelease()
        trace.record("joined")
        #expect(release.commit == SQLITE_OK && release.close == SQLITE_OK, Comment(rawValue: trace.summary))
        return (firstResult, secondResult)
    }
}

@MainActor @Suite struct EmbeddingMigrationRaceTests {
    @Test(arguments: [0, 2])
    func concurrentConnectionsReadSchemaOnlyAfterAcquiringMigrationLock(version: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-race-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        let sentinel: KnowledgeProject?
        if version == 2 { sentinel = try await ProjectStore(url: url).createProject(name: "Существующий проект") }
        else { sentinel = nil }
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        if version == 2 {
            #expect(sqlite3_exec(db, "DROP TABLE embedding_vectors; DROP TABLE embedding_jobs; DROP TABLE embedding_chunks; DROP TABLE embedding_sources; DROP TABLE embedding_source_epochs; DROP TABLE embedding_active_model; DROP TABLE embedding_models; PRAGMA user_version=2", nil, nil, nil) == SQLITE_OK)
        }
        let trace = MigrationTrace(version: version)
        let heldLock = try MigrationReservedLock(url: url, trace: trace)
        let first = ProjectStore(url: url), second = ProjectStore(url: url)
        let (one, two) = await MigrationRace.run(lock: heldLock, trace: trace,
            first: { try await first.snapshot() }, second: { try await second.snapshot() })
        // Both tasks and the fixture connection have finished before errors propagate.
        if case .failure = one { Issue.record(Comment(rawValue: trace.summary)) }
        if case .failure = two { Issue.record(Comment(rawValue: trace.summary)) }
        let firstSnapshot = try one.get(), secondSnapshot = try two.get()
        #expect(firstSnapshot == secondSnapshot)
        #expect(firstSnapshot.projects == sentinel.map { [$0] } ?? [])
        #expect(try await first.embeddingJobs().isEmpty)
        #expect(try await second.embeddingJobs().isEmpty)
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "synthetic")
        #expect(try await first.observeEmbeddingSource(key) == second.observeEmbeddingSource(key))
        // No writer remains before teardown. This is a real exclusive lock, not a mock.
        #expect(sqlite3_exec(db, "BEGIN EXCLUSIVE; ROLLBACK", nil, nil, nil) == SQLITE_OK, Comment(rawValue: trace.summary))
        #expect(MigrationRace.hasContentionEvidence(trace), Comment(rawValue: trace.summary))
    }

    @Test func firstFailureStillWaitsForSecondConnectionAndReleaseBeforeTeardown() async throws {
        enum SyntheticFailure: Error, Equatable { case first }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        let sentinel = try await ProjectStore(url: url).createProject(name: "Сохранить")
        let trace = MigrationTrace(version: 3)
        let heldLock = try MigrationReservedLock(url: url, trace: trace)
        let second = ProjectStore(url: url)
        let (one, two) = await MigrationRace.run(lock: heldLock, trace: trace, expected: ["second"],
            first: { throw SyntheticFailure.first }, second: { try await second.snapshot() })
        #expect(throws: SyntheticFailure.first) { try one.get() }
        #expect(try two.get().projects == [sentinel])
        let events = trace.events
        let failed = try #require(events.first { $0.name == "first-failure" })
        let released = try #require(events.first { $0.name == "release-start" })
        let succeeded = try #require(events.first { $0.name == "second-success" })
        let joined = try #require(events.first { $0.name == "joined" })
        #expect(failed.milliseconds < released.milliseconds, Comment(rawValue: trace.summary))
        #expect(succeeded.milliseconds <= joined.milliseconds, Comment(rawValue: trace.summary))
        #expect(events.first { $0.name == "close-result" }?.result == SQLITE_OK)
        #expect(MigrationRace.hasContentionEvidence(trace, expected: ["second"]), Comment(rawValue: trace.summary))
        // A fresh real writer succeeds before the temporary directory is removed.
        let writer = try ProjectDatabase(url: url)
        try writer.execute("BEGIN EXCLUSIVE")
        try writer.execute("ROLLBACK")
        #expect(try writer.rows("PRAGMA user_version") == [["3"]])
        #expect(try await ProjectStore(url: url).snapshot().projects == [sentinel])
    }

    @Test(arguments: [false, true])
    func delayedActorExecutionRequiresRealSQLiteEntries(prematureRelease: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-delayed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        // Create an actual v0 file, not a pre-migrated store.
        do { _ = try ProjectDatabase(url: url) }
        let trace = MigrationTrace(version: 0)
        let heldLock = try MigrationReservedLock(url: url, trace: trace)
        let first = ProjectStore(url: url), second = ProjectStore(url: url)
        let (one, two) = await MigrationRace.run(lock: heldLock, trace: trace,
            policy: prematureRelease ? .prematureNegativeControl : .afterSQLiteEntries,
            first: {
                if prematureRelease { _ = await heldLock.waitForRelease() }
                try await Task.sleep(for: .milliseconds(650))
                trace.record("first-snapshot-call")
                return try await first.snapshot()
            }, second: {
                if prematureRelease { _ = await heldLock.waitForRelease() }
                try await Task.sleep(for: .milliseconds(900))
                trace.record("second-snapshot-call")
                return try await second.snapshot()
            })
        #expect(try one.get() == two.get())
        // The SAME predicate used by v0/v2 must reject the old false-positive path.
        #expect(MigrationRace.hasContentionEvidence(trace) == !prematureRelease, Comment(rawValue: trace.summary))
        let events = trace.events
        let released = try #require(events.first { $0.name == "release-start" })
        if prematureRelease {
            for label in ["first-snapshot-call", "second-snapshot-call", "first-sqlite-begin", "second-sqlite-begin"] {
                #expect(try #require(events.first { $0.name == label }).milliseconds > released.milliseconds,
                        Comment(rawValue: trace.summary))
            }
        }
        let writer = try ProjectDatabase(url: url)
        try writer.execute("BEGIN EXCLUSIVE")
        try writer.execute("ROLLBACK")
        #expect(try writer.rows("PRAGMA user_version") == [["3"]])
    }

    @Test func delayedPeerDoesNotSpendFirstConnectionsSQLiteBusyTimeoutBeforeContention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-scheduler-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        do { _ = try ProjectDatabase(url: url) }
        let trace = MigrationTrace(version: 0)
        let heldLock = try MigrationReservedLock(url: url, trace: trace)
        let first = ProjectStore(url: url), second = ProjectStore(url: url)
        let (one, two) = await MigrationRace.run(lock: heldLock, trace: trace,
            first: { try await first.snapshot() }, second: {
                // Longer than the unchanged production busy_timeout (2000 ms).
                try await Task.sleep(for: .milliseconds(2500))
                return try await second.snapshot()
            })
        #expect(try one.get() == two.get())
        #expect(MigrationRace.hasContentionEvidence(trace), Comment(rawValue: trace.summary))
        #expect(!trace.events.contains { $0.name.contains("timeout") }, Comment(rawValue: trace.summary))
    }

}
