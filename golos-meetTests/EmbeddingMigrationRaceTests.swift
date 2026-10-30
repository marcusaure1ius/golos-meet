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
    }
    let scenario = UUID()
    let version: Int
    private let started = ProcessInfo.processInfo.systemUptime
    private let mutex = NSLock()
    private var entries: [Event] = []
    init(version: Int) { self.version = version }
    var milliseconds: Double { (ProcessInfo.processInfo.systemUptime - started) * 1000 }
    func record(_ name: String, result: Int32? = nil, extended: Int32? = nil,
                scheduledMilliseconds: Double? = nil, error: (any Error)? = nil) {
        let diagnostic: ProjectDatabase.Diagnostic?
        if let error = error as? ProjectStoreError, case .database(let message) = error {
            diagnostic = try? JSONDecoder().decode(ProjectDatabase.Diagnostic.self, from: Data(message.utf8))
        } else { diagnostic = nil }
        let entry = Event(name: name, milliseconds: milliseconds, result: result,
                          extended: extended, scheduledMilliseconds: scheduledMilliseconds, diagnostic: diagnostic)
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
    /// The release deadline starts only after both child tasks have actually started.
    /// Merely creating Task handles is insufficient under a busy test executor.
    private nonisolated final class Starts: @unchecked Sendable {
        private let mutex = NSLock()
        private var remaining = 2
        private let ready = DispatchSemaphore(value: 0)
        private var opened = false
        private var entrants: [CheckedContinuation<Void, Never>] = []
        func arrive() async {
            await withCheckedContinuation { continuation in
                mutex.lock()
                remaining -= 1
                let bothStarted = remaining == 0
                let proceed = opened
                if !proceed { entrants.append(continuation) }
                mutex.unlock()
                if bothStarted { ready.signal() }
                if proceed { continuation.resume() }
            }
        }
        func open() {
            mutex.lock()
            opened = true
            let pending = entrants
            entrants.removeAll()
            mutex.unlock()
            for entrant in pending { entrant.resume() }
        }
        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                // The watchdog must also run independently of the executor whose
                // startup delay we are measuring. Its timeout uses a monotonic clock.
                let watchdog = Thread { [self] in
                    let started = ready.wait(timeout: .now() + 5) == .success
                    continuation.resume(returning: started)
                }
                watchdog.name = "golos-migration-fixture-start-watchdog"
                watchdog.qualityOfService = .userInitiated
                watchdog.start()
            }
        }
    }

    private static func capture(_ label: String, trace: MigrationTrace, starts: Starts,
                        work: @Sendable () async throws -> ProjectSnapshot) async -> Result<ProjectSnapshot, any Error> {
        trace.record(label + "-start")
        await starts.arrive()
        do { let value = try await work(); trace.record(label + "-success"); return .success(value) }
        catch { trace.record(label + "-failure", error: error); return .failure(error) }
    }
    static func run(lock: MigrationReservedLock, trace: MigrationTrace,
                    first: @escaping @Sendable () async throws -> ProjectSnapshot,
                    second: @escaping @Sendable () async throws -> ProjectSnapshot) async -> (Result<ProjectSnapshot, any Error>, Result<ProjectSnapshot, any Error>) {
        let starts = Starts()
        let one = Task.detached { await capture("first", trace: trace, starts: starts, work: first) }
        let two = Task.detached { await capture("second", trace: trace, starts: starts, work: second) }
        let bothStarted = await starts.wait()
        if !bothStarted { trace.record("startup-timeout") }
        // Even on a failed startup barrier, release the real lock and join both
        // children before allowing the caller to remove the temporary database.
        lock.releaseAfterDelay(bothStarted ? 0.5 : 0)
        starts.open()
        #expect(bothStarted, Comment(rawValue: trace.summary))
        // Await BOTH Results before propagating either error, including first-task failure.
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
        let events = trace.events
        let released = try #require(events.first { $0.name == "release-start" })
        for label in ["first-start", "second-start"] {
            #expect(try #require(events.first { $0.name == label }).milliseconds < released.milliseconds,
                    Comment(rawValue: trace.summary))
        }
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
        let (one, two) = await MigrationRace.run(lock: heldLock, trace: trace,
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
        // A fresh real writer succeeds before the temporary directory is removed.
        let writer = try ProjectDatabase(url: url)
        try writer.execute("BEGIN EXCLUSIVE")
        try writer.execute("ROLLBACK")
        #expect(try writer.rows("PRAGMA user_version") == [["3"]])
        #expect(try await ProjectStore(url: url).snapshot().projects == [sentinel])
    }

}
