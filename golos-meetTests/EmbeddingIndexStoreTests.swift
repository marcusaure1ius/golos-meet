import Foundation
import SQLite3
import Testing
@testable import golos_meet

/// Small unit vectors exercise storage/transactions only. Real E5 persistence
/// and filesystem races have a separate opt-in native test below.
@MainActor @Suite struct EmbeddingIndexStoreTests {
    private let model = EmbeddingIndexModel(id: "synthetic-storage-fixture", dimensions: 3)
    private let textA = "Решили перенести запуск на декабрь. Ответственный Анна."
    private let textB = "Запуск перенесён на январь. Ответственный Борис."

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embedding-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func importer(_ root: URL, _ store: ProjectStore) -> DocumentImporter {
        DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
    }
    private func put(_ root: URL, store: ProjectStore, text: String, target: UUID? = nil, owners: Set<UUID> = []) async throws -> LibraryDocument {
        let file = root.appendingPathComponent("Решения.txt")
        try Data(text.utf8).write(to: file)
        let result = try await importer(root, store).importFile(id: UUID(), url: file, projectIDs: owners, targetID: target) { _ in }
        return try #require(try await store.documents().first { $0.id == result.documentID })
    }
    private func results(_ lease: EmbeddingIndexLease) throws -> [IndexedChunkVectors] {
        try lease.snapshot.chunks.map { chunk in
            .init(chunkID: chunk.id, bodyTokenCount: 20, windows: [
                .init(tokenStart: 0, tokenCount: 20, vector: try KnowledgeVector(modelID: lease.model.id, values: Array(repeating: 1, count: lease.model.dimensions)))
            ])
        }
    }
    private func sql(_ url: URL, _ query: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
    private func scalar(_ url: URL, _ query: String) throws -> Int {
        var db: OpaquePointer?; var statement: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @Test func sharedSourceIsStoredOnceAndSurvivesRestartWithIdentityAndLocations() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ProjectStore(url: url)
        let a = try await store.createProject(name: "А"), b = try await store.createProject(name: "Б")
        let doc = try await put(root, store: store, text: textA + "\0Проверка UTF-8", owners: [a.id, b.id])
        #expect(try await store.embeddingJobs().first?.state == .waitingForModel)
        #expect(try await store.claimEmbeddingJob() == nil)
        try await store.activateEmbeddingModel(model)
        let lease = try #require(try await store.claimEmbeddingJob())
        let key = lease.job.source
        #expect(lease.snapshot.revision == doc.currentVersion.id.uuidString)
        #expect(lease.snapshot.chunks == (try await store.chunks(for: doc.currentVersion.id)))
        #expect(try await store.publishEmbeddingVectors(results(lease), lease: lease))
        let reopened = ProjectStore(url: url)
        let windows = try await reopened.embeddingWindows(for: key, model: model)
        #expect(windows.count == lease.snapshot.chunks.count)
        #expect(windows.allSatisfy { $0.source == key && $0.revision == doc.currentVersion.id.uuidString && $0.tokenStart == 0 && $0.tokenCount == 20 })
        #expect(windows.first?.chunk.text.contains("\0") == true)
        #expect(windows.first?.chunk.location == lease.snapshot.chunks.first?.location)
        #expect(windows.first?.vector.modelID == model.id)
        #expect(try scalar(url, "SELECT COUNT(*) FROM embedding_sources") == 1)
        #expect(try scalar(url, "SELECT SUM(length(vector)) FROM embedding_vectors") == windows.count * 12)
        _ = try await put(root, store: reopened, text: textA + "\0Проверка UTF-8", owners: [b.id])
        try await reopened.synchronizeEmbeddingDocuments()
        #expect(try await reopened.embeddingJobs().first?.generation == lease.job.generation)
        #expect(try await reopened.embeddingJobs().first?.state == .ready)
        #expect(try await reopened.documents().first?.projectIDs == [a.id, b.id])
    }

    @Test func actualDocumentVersionABARejectsLateResultProgressAndFailure() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ProjectStore(url: url)
        let first = try await put(root, store: store, text: textA)
        try await store.activateEmbeddingModel(model)
        let old = try #require(try await store.claimEmbeddingJob())
        let computed = try results(old)
        let second = try await put(root, store: store, text: textB, target: first.id)
        #expect(second.currentVersion.id != first.currentVersion.id)
        let restored = try await put(root, store: store, text: textA, target: first.id)
        #expect(restored.currentVersion.id == first.currentVersion.id)
        #expect(try await store.embeddingJobs().first?.generation != old.job.generation)
        #expect(try await store.updateEmbeddingProgress(old, completed: old.job.total) == false)
        #expect(try await store.failEmbeddingJob(old) == false)
        #expect(try await store.publishEmbeddingVectors(computed, lease: old) == false)
        #expect(try await store.embeddingWindows(for: old.job.source, model: model).isEmpty)
        let current = try #require(try await store.claimEmbeddingJob())
        #expect(try await store.publishEmbeddingVectors(results(current), lease: current))
        #expect(try await store.documents().first?.versionCount == 2)
        #expect(try Data(contentsOf: await importer(root, store).fileURL(for: first.currentVersion)) == Data(textA.utf8))
    }

    @Test func modelABAAndDimensionReuseCannotAcceptAnOldLease() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await put(root, store: store, text: textA)
        try await store.activateEmbeddingModel(model)
        let old = try #require(try await store.claimEmbeddingJob())
        let alternate = EmbeddingIndexModel(id: "other-synthetic-fixture", dimensions: 2)
        try await store.activateEmbeddingModel(alternate)
        await #expect(throws: EmbeddingIndexError.invalidModel) { try await store.embeddingWindows(for: old.job.source, model: model) }
        try await store.activateEmbeddingModel(model)
        #expect(try await store.embeddingJobs().first?.generation != old.job.generation)
        #expect(try await store.publishEmbeddingVectors(results(old), lease: old) == false)
        let current = try #require(try await store.claimEmbeddingJob())
        await #expect(throws: EmbeddingIndexError.invalidModel) {
            try await store.activateEmbeddingModel(.init(id: model.id, dimensions: 2))
        }
        #expect(try await store.publishEmbeddingVectors(results(current), lease: current))
        #expect(try await store.embeddingWindows(for: current.job.source, model: model).first?.vector.values.count == 3)
    }

    @Test func leasesAreExclusiveAndCancelRetryAndRestartInvalidateOldAttempts() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ProjectStore(url: url)
        _ = try await put(root, store: store, text: textA)
        try await store.activateEmbeddingModel(model)
        let cancelled = try #require(try await store.claimEmbeddingJob())
        let secondConnection = ProjectStore(url: url)
        #expect(try await secondConnection.claimEmbeddingJob() == nil)
        try await store.cancelEmbeddingJob(cancelled.job.source)
        try await store.retryEmbeddingJob(cancelled.job.source)
        let interrupted = try #require(try await secondConnection.claimEmbeddingJob())
        #expect(try await store.failEmbeddingJob(cancelled) == false)
        #expect(try await store.updateEmbeddingProgress(cancelled, completed: 1) == false)
        #expect(try await store.publishEmbeddingVectors(results(cancelled), lease: cancelled) == false)
        let restarted = ProjectStore(url: url)
        try await restarted.recoverEmbeddingJobs()
        let current = try #require(try await restarted.claimEmbeddingJob())
        #expect(current.job.generation != interrupted.job.generation && current.attempt != interrupted.attempt)
        #expect(try await store.publishEmbeddingVectors(results(interrupted), lease: interrupted) == false)
        #expect(try await restarted.updateEmbeddingProgress(current, completed: 1))
        #expect(try await restarted.updateEmbeddingProgress(current, completed: 0))
        #expect(try await restarted.embeddingJobs().first?.completed == 1)
        #expect(try await restarted.publishEmbeddingVectors(results(current), lease: current))
        #expect(try await restarted.publishEmbeddingVectors(results(current), lease: current) == false)
    }

    @Test func partialCoverageWrongIdentityAndTransactionFailureNeverPublishPartialVectors() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ProjectStore(url: url)
        _ = try await put(root, store: store, text: String(repeating: textA + " ", count: 55))
        try await store.activateEmbeddingModel(model)
        let lease = try #require(try await store.claimEmbeddingJob())
        var good = try results(lease)
        good[0] = .init(chunkID: good[0].chunkID, bodyTokenCount: 20, windows: [
            .init(tokenStart: 0, tokenCount: 14, vector: good[0].windows[0].vector),
            .init(tokenStart: 10, tokenCount: 10, vector: good[0].windows[0].vector)
        ])
        #expect(good.count > 1)
        await #expect(throws: EmbeddingIndexError.invalidVectors) { try await store.publishEmbeddingVectors(Array(good.dropLast()), lease: lease) }
        var gap = good
        gap[0] = .init(chunkID: good[0].chunkID, bodyTokenCount: 20, windows: [
            .init(tokenStart: 1, tokenCount: 19, vector: good[0].windows[0].vector)
        ])
        await #expect(throws: EmbeddingIndexError.invalidVectors) { try await store.publishEmbeddingVectors(gap, lease: lease) }
        var wrong = good
        wrong[0] = .init(chunkID: good[0].chunkID, bodyTokenCount: 20, windows: [
            .init(tokenStart: 0, tokenCount: 20, vector: try KnowledgeVector(modelID: "wrong-model", values: [1, 1, 1]))
        ])
        await #expect(throws: EmbeddingIndexError.invalidVectors) { try await store.publishEmbeddingVectors(wrong, lease: lease) }
        try sql(url, "CREATE TRIGGER reject_vector BEFORE INSERT ON embedding_vectors WHEN NEW.chunk_id = '\(good[1].chunkID)' BEGIN SELECT RAISE(ABORT, 'synthetic disk failure'); END")
        await #expect(throws: ProjectStoreError.self) { try await store.publishEmbeddingVectors(good, lease: lease) }
        #expect(try scalar(url, "SELECT COUNT(*) FROM embedding_vectors") == 0)
        #expect(try await store.embeddingJobs().first?.state == .running)
        #expect(try await store.embeddingWindows(for: lease.job.source, model: model).isEmpty)
        try sql(url, "DROP TRIGGER reject_vector")
        #expect(try await store.publishEmbeddingVectors(good, lease: lease))
        try sql(url, "DELETE FROM embedding_vectors WHERE chunk_id = '\(good[0].chunkID)' AND token_start = 10")
        await #expect(throws: EmbeddingIndexError.corruptIndex) { try await store.embeddingWindows(for: lease.job.source, model: model) }
        try await store.requestEmbeddingReindex(lease.job.source)
        let repaired = try #require(try await store.claimEmbeddingJob())
        #expect(try await store.publishEmbeddingVectors(good, lease: repaired))
        try sql(url, "UPDATE embedding_vectors SET vector = zeroblob(dimensions * 4)")
        await #expect(throws: EmbeddingIndexError.corruptIndex) { try await store.embeddingWindows(for: lease.job.source, model: model) }
    }

    @Test func importAndEmbeddingInvalidationRollbackTogether() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ProjectStore(url: url)
        let doc = try await put(root, store: store, text: textA)
        try await store.activateEmbeddingModel(model)
        let lease = try #require(try await store.claimEmbeddingJob())
        #expect(try await store.publishEmbeddingVectors(results(lease), lease: lease))
        try sql(url, "CREATE TRIGGER reject_invalidation BEFORE UPDATE ON embedding_sources BEGIN SELECT RAISE(ABORT, 'synthetic catalog failure'); END")
        await #expect(throws: ProjectStoreError.self) { try await put(root, store: store, text: textB, target: doc.id) }
        #expect(try await store.documents().first?.currentVersion.id == doc.currentVersion.id)
        #expect(try await store.documents().first?.versionCount == 1)
        #expect(try await store.embeddingJobs().first?.generation == lease.job.generation)
        #expect(try await store.embeddingWindows(for: lease.job.source, model: model).count == lease.snapshot.chunks.count)
    }

    @Test func removalCascadesDerivedDataAndRecreatedSameSourceRejectsOldLease() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ProjectStore(url: url)
        let doc = try await put(root, store: store, text: textA)
        try await store.activateEmbeddingModel(model)
        let first = try #require(try await store.claimEmbeddingJob())
        #expect(try await store.publishEmbeddingVectors(results(first), lease: first))
        try await store.requestEmbeddingReindex(first.job.source)
        let removed = try #require(try await store.claimEmbeddingJob())
        try await store.removeEmbeddingSource(removed.job.source)
        #expect(try await store.embeddingJobs().isEmpty)
        #expect(try scalar(url, "SELECT COUNT(*) FROM embedding_vectors") == 0)
        #expect(try await store.publishEmbeddingVectors(results(removed), lease: removed) == false)
        try await store.synchronizeEmbeddingDocuments()
        let current = try #require(try await store.claimEmbeddingJob())
        #expect(current.snapshot.revision == removed.snapshot.revision)
        #expect(current.job.generation != removed.job.generation)
        #expect(try await store.publishEmbeddingVectors(results(removed), lease: removed) == false)
        #expect(try await store.publishEmbeddingVectors(results(current), lease: current))
        #expect(try Data(contentsOf: await importer(root, store).fileURL(for: doc.currentVersion)) == Data(textA.utf8))
    }

    @Test func migrationKeepsLegacyDocumentsAndRollsBackFailedSchemaChanges() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = ProjectStore(url: url)
        let doc = try await put(root, store: store, text: textA)
        try removeAssignmentMigrationObjects(url)
        try sql(url, "DROP TABLE knowledge_fts; DROP TABLE knowledge_model_epoch; DROP TABLE embedding_vectors; DROP TABLE embedding_jobs; DROP TABLE embedding_chunks; DROP TABLE embedding_sources; DROP TABLE embedding_source_epochs; DROP TABLE embedding_active_model; DROP TABLE embedding_models; PRAGMA user_version=2; CREATE TABLE embedding_sources(keep TEXT); INSERT INTO embedding_sources VALUES ('original')")
        await #expect(throws: ProjectStoreError.self) { try await ProjectStore(url: url).snapshot() }
        #expect(try scalar(url, "PRAGMA user_version") == 2)
        #expect(try scalar(url, "SELECT COUNT(*) FROM sqlite_master WHERE name='embedding_models'") == 0)
        #expect(try scalar(url, "SELECT COUNT(*) FROM embedding_sources WHERE keep='original'") == 1)
        try sql(url, "DROP TABLE embedding_sources")
        let migrated = ProjectStore(url: url)
        try await migrated.synchronizeEmbeddingDocuments()
        #expect(try scalar(url, "PRAGMA user_version") == 8)
        #expect(try await migrated.documents().first?.currentVersion == doc.currentVersion)
        #expect(try await migrated.embeddingJobs().first?.state == .waitingForModel)
        #expect(try Data(contentsOf: await importer(root, migrated).fileURL(for: doc.currentVersion)) == Data(textA.utf8))
    }
}
