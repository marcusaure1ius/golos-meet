import Foundation
import SQLite3
import Testing
@testable import golos_meet

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
        #expect(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        let first = ProjectStore(url: url), second = ProjectStore(url: url)
        let one = Task.detached { try await first.snapshot() }
        let two = Task.detached { try await second.snapshot() }
        // The held reserved lock permits old pre-lock reads of user_version but
        // blocks both BEGIN IMMEDIATE calls. Both connections contend as in the
        // independently reproduced race; no test hook changes production code.
        try await Task.sleep(for: .milliseconds(500))
        #expect(sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK)
        let firstSnapshot = try await one.value
        let secondSnapshot = try await two.value
        #expect(firstSnapshot == secondSnapshot)
        #expect(firstSnapshot.projects == sentinel.map { [$0] } ?? [])
        #expect(try await first.embeddingJobs().isEmpty)
        #expect(try await second.embeddingJobs().isEmpty)
        // Both use the migrated catalog, including observations of absence.
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "synthetic")
        #expect(try await first.observeEmbeddingSource(key) == second.observeEmbeddingSource(key))
    }
}
