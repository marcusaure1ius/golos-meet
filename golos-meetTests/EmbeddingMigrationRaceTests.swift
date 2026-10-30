import Foundation
import SQLite3
import Testing
@testable import golos_meet

/// Owns a real reserved lock. Release runs independently of MainActor so other
/// AppKit/native tests cannot accidentally hold it past the production timeout.
private nonisolated final class MigrationReservedLock: @unchecked Sendable {
    private let handle: OpaquePointer
    private let mutex = NSLock()
    private var result: Int32?

    init(url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw CocoaError(.fileReadUnknown)
        }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileWriteUnknown)
        }
        handle = db
    }
    deinit { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
    func releaseAfterDelay() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(500)) { [self] in
            mutex.lock(); defer { mutex.unlock() }
            result = sqlite3_exec(handle, "COMMIT", nil, nil, nil)
        }
    }
    var releaseResult: Int32? {
        mutex.lock(); defer { mutex.unlock() }
        return result
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
        if version == 2 {
            sentinel = try await ProjectStore(url: url).createProject(name: "Существующий проект")
        } else { sentinel = nil }
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        if version == 2 {
            // A genuine v2 fixture: preserve its data, remove every v3 table.
            #expect(sqlite3_exec(db, "DROP TABLE embedding_vectors; DROP TABLE embedding_jobs; DROP TABLE embedding_chunks; DROP TABLE embedding_sources; DROP TABLE embedding_source_epochs; DROP TABLE embedding_active_model; DROP TABLE embedding_models; PRAGMA user_version=2", nil, nil, nil) == SQLITE_OK)
        }
        let heldLock = try MigrationReservedLock(url: url)
        let first = ProjectStore(url: url), second = ProjectStore(url: url)
        let one = Task.detached { try await first.snapshot() }
        let two = Task.detached { try await second.snapshot() }
        // The held reserved lock permits old pre-lock reads of user_version but
        // blocks both BEGIN IMMEDIATE calls. Both connections contend as in the
        // independently reproduced race; no test hook changes production code.
        heldLock.releaseAfterDelay()
        let firstSnapshot = try await one.value
        let secondSnapshot = try await two.value
        #expect(heldLock.releaseResult == SQLITE_OK)
        #expect(firstSnapshot == secondSnapshot)
        #expect(firstSnapshot.projects == sentinel.map { [$0] } ?? [])
        #expect(try await first.embeddingJobs().isEmpty)
        #expect(try await second.embeddingJobs().isEmpty)
        // Both use the migrated catalog, including observations of absence.
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "synthetic")
        #expect(try await first.observeEmbeddingSource(key) == second.observeEmbeddingSource(key))
    }
}
