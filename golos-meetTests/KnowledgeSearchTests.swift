import Foundation
import CryptoKit
import SQLite3
import Testing
@testable import golos_meet

private actor SearchFixtureEncoder: LocalPassageEmbedding {
    nonisolated let modelID = "synthetic-search"
    nonisolated let dimensions = 2
    func embed(_ texts: [String], purpose: EmbeddingPurpose) throws -> [KnowledgeVector] {
        try texts.map { text in try KnowledgeVector(modelID: modelID, values: purpose == .query || text.contains("транспорт") ? [1, 0] : [0, 1]) }
    }
    func passageWindows(_ text: String) throws -> [EmbeddedPassageWindow] {
        [.init(tokenStart: 0, tokenCount: 3, vector: try embed([text], purpose: .passage)[0])]
    }
}

@MainActor @Suite(SQLiteFixtureTrait()) struct KnowledgeSearchTests {
    @MainActor private struct Fixture {
        let root: URL
        let store: ProjectStore
        let indexer: LocalIndexingService
        let importer: DocumentImporter
        let encoder = SearchFixtureEncoder()
        let resources: SearchIndexFixtureCleanup
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-search-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let scope = try #require(SQLiteFixtureScope.current)
            scope.register(root: root)
            resources = .init(scope: scope)
            store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
            importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
            let encoder = self.encoder
            indexer = LocalIndexingService(store: store, meetingsRoot: root.appendingPathComponent("meetings"), inspect: {
                .init(model: .init(id: encoder.modelID, dimensions: encoder.dimensions), folder: nil, load: { encoder })
            })
            resources.track(indexer, store: store)
        }
        func cleanup() async { await resources.finish() }
        func reopenedStore() -> ProjectStore {
            let reopened = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
            resources.own(reopened)
            return reopened
        }
        func model(service: KnowledgeSearchService) -> KnowledgeSearchModel {
            let model = KnowledgeSearchModel(service: service)
            resources.own(model)
            return model
        }
        func service(budget: Int = 20_000, query: KnowledgeSearchService.QueryEmbedding? = nil) -> KnowledgeSearchService {
            let encoder = encoder
            let indexer = indexer
            return KnowledgeSearchService(store: store, meetingsRoot: root.appendingPathComponent("meetings"),
                documentsRoot: root.appendingPathComponent("copies"), windowBudget: budget,
                queryEmbedding: query ?? { try await encoder.embed([$0], purpose: .query)[0] },
                sourceChanged: { await indexer.changed(source: $0) })
        }
        func document(_ text: String, projects: Set<UUID> = [], target: UUID? = nil) async throws -> UUID {
            let file = root.appendingPathComponent("\(UUID()).txt")
            try Data(text.utf8).write(to: file)
            return try await importer.importFile(id: UUID(), url: file, projectIDs: projects, targetID: target) { _ in }.documentID
        }
        func meeting(_ id: String, text: String, start: Double = 12) async throws -> URL {
            let folder = root.appendingPathComponent("meetings/\(id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("transcript.json")
            try JSONSerialization.data(withJSONObject: ["meetingId": id, "segments": [["start": start, "end": start + 6, "text": text]]])
                .write(to: file, options: .atomic)
            let reader = MeetingEmbeddingSnapshotReader(root: root.appendingPathComponent("meetings"))
            _ = try await reader.synchronize(meetingID: id, store: store)
            return file
        }
    }

    @Test func russianLexicalSearchWorksBeforeWeightsAndUsesExactProjectAndInboxMembership() async throws {
        let f = try Fixture()
        do {
            let p = try await f.store.createProject(name: "Запуск"), q = try await f.store.createProject(name: "Другой")
            let child = try await f.store.createProject(name: "Дочерний", parentID: p.id)
            let shared = try await f.document("Релиз согласован на декабрь", projects: [p.id, q.id])
            let childDoc = try await f.document("Релиз дочернего проекта", projects: [child.id])
            let inbox = try await f.document("Релиз без проекта")
            _ = try await f.meeting("shared", text: "РЕЛИЗ на январь")
            try await f.store.assignMeeting("shared", to: [p.id, q.id])
            let search = f.service()
            let response = try await search.search("релиз", scope: .project(p.id))
            #expect(Set(response.hits.map { $0.source.key.externalID }) == [shared.uuidString, "shared"])
            #expect(response.semanticMessage != nil && response.hits.allSatisfy { $0.matchedWords && !$0.matchedMeaning })
            #expect(try await search.search("релиз", scope: .inbox).hits.map { $0.source.key.externalID } == [inbox.uuidString])
            #expect(try await search.search("релиз", scope: .project(child.id)).hits.map { $0.source.key.externalID } == [childDoc.uuidString])
            let meetingHit = try #require(response.hits.first { $0.source.key.kind == .meeting })
            let destination = try await search.open(meetingHit)
            #expect(destination.chunks.contains { $0.location.startSeconds == 12 && $0.text == "РЕЛИЗ на январь" })
            try await f.store.assignMeeting("shared", to: [])
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(meetingHit) }
            #expect(try await search.search("несуществующееслово", scope: .all).hits.isEmpty)
            await #expect(throws: KnowledgeSearchError.scopeUnavailable) { try await search.search("релиз", scope: .project(UUID())) }
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func fusionIncludesWordsAndSemanticOnlyHitAndReportsBudgetWithoutMixingVectors() async throws {
        let f = try Fixture()
        do {
            let both = try await f.document("машина и транспорт"), semantic = try await f.document("общественный транспорт")
            let lexical = try await f.document("машина на парковке")
            await f.indexer.start(); await f.indexer.waitUntilIdle()
            let response = try await f.service().search("машина", scope: .all)
            #expect(response.hits.first?.source.key.externalID == both.uuidString)
            #expect(response.hits.contains { $0.source.key.externalID == semantic.uuidString && !$0.matchedWords && $0.matchedMeaning })
            #expect(response.hits.contains { $0.source.key.externalID == lexical.uuidString && $0.matchedWords && !$0.matchedMeaning })
            let bounded = try await f.service(budget: 0).search("машина", scope: .all)
            #expect(bounded.limited && bounded.hits.allSatisfy { $0.matchedWords && !$0.matchedMeaning })
            let incompatible = f.service(query: { _ in try KnowledgeVector(modelID: "synthetic-search", values: [1, 0, 0]) })
            await #expect(throws: KnowledgeSearchError.modelChanged) { try await incompatible.search("машина", scope: .all) }
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func documentUpdateAndGenerationChangesInvalidateOldHitsEvenAfterSelectingOldBytesAgain() async throws {
        let f = try Fixture()
        do {
            let id = try await f.document("Релиз первая версия")
            let search = f.service()
            let hit = try #require(try await search.search("релиз", scope: .all).hits.first)
            _ = try await f.document("Релиз новая версия", target: id)
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(hit) }
            _ = try await f.document("Релиз первая версия", target: id)
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(hit) }
            let fresh = try #require(try await search.search("релиз", scope: .all).hits.first)
            #expect(try await search.open(fresh).chunks.first?.text == "Релиз первая версия")
            try await f.store.requestEmbeddingReindex(fresh.source.key)
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(fresh) }
            #expect(try await search.search("новая", scope: .all).hits.isEmpty) // FTS delete/reinsert triggers
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func filesystemABAAndRecreationAreRejectedBeforeObserverSeesThem() async throws {
        let f = try Fixture()
        do {
            let file = try await f.meeting("a", text: "Релиз старый", start: 5)
            let bytes = try Data(contentsOf: file), search = f.service()
            let hit = try #require(try await search.search("релиз", scope: .all).hits.first)
            let date = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            try Data("{broken".utf8).write(to: file)
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(hit) }
            let fresh = try #require(try await search.search("релиз", scope: .all).hits.first)
            try FileManager.default.removeItem(at: file.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(fresh) }
            let current = try #require(try await search.search("релиз", scope: .all).hits.first)
            try await f.store.removeEmbeddingSource(current.source.key)
            _ = try await MeetingEmbeddingSnapshotReader(root: f.root.appendingPathComponent("meetings")).synchronize(meetingID: "a", store: f.store)
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(current) }
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func lateQueryRejectsModelABAAndFileChangesInsteadOfOpeningWrongTimecode() async throws {
        let f = try Fixture()
        do {
            let file = try await f.meeting("a", text: "Релиз транспорт", start: 5)
            await f.indexer.start(); await f.indexer.waitUntilIdle()
            let entered = IndexGate(), release = IndexGate(), encoder = f.encoder
            let search = f.service(query: { text in
                await entered.signal(); await release.wait()
                return try await encoder.embed([text], purpose: .query)[0]
            })
            f.resources.own(release)
            let pending = Task { try await search.search("релиз", scope: .all) }
            f.resources.own(pending)
            await entered.wait()
            let bytes = try Data(contentsOf: file)
            try Data("different".utf8).write(to: file, options: .atomic)
            try bytes.write(to: file, options: .atomic)
            await release.signal()
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await pending.value }
            let modelEntered = IndexGate(), modelRelease = IndexGate()
            let modelSearch = f.service(query: { text in
                await modelEntered.signal(); await modelRelease.wait()
                return try await encoder.embed([text], purpose: .query)[0]
            })
            f.resources.own(modelRelease)
            let late = Task { try await modelSearch.search("релиз", scope: .all) }
            f.resources.own(late)
            await modelEntered.wait()
            try await f.store.activateEmbeddingModel(.init(id: "synthetic-other", dimensions: 2))
            try await f.store.activateEmbeddingModel(.init(id: encoder.modelID, dimensions: 2))
            await modelRelease.signal()
            await #expect(throws: KnowledgeSearchError.modelChanged) { try await late.value }
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func querySyntaxIsDataAndLimitsAreExplicit() throws {
        #expect(try KnowledgeSearchQuery.expression("релиз OR \"запуск\" -NOT: NEAR(*)") == "\"релиз\"* OR \"OR\"* OR \"запуск\"* OR \"NOT\"* OR \"NEAR\"*")
        #expect(throws: KnowledgeSearchError.invalidQuery) { try KnowledgeSearchQuery.expression("***") }
        #expect(throws: KnowledgeSearchError.invalidQuery) { try KnowledgeSearchQuery.expression(String(repeating: "а", count: 257)) }
    }

    @Test func v3MigrationRebuildsFTSAndFailureRollsBackWithoutChangingOriginalRecords() async throws {
        let f = try Fixture()
        do {
            let id = try await f.document("Релиз сохраняется при миграции")
            let url = f.root.appendingPathComponent("knowledge.sqlite")
            let downgrade = "DROP TRIGGER knowledge_fts_insert; DROP TRIGGER knowledge_fts_delete; DROP TRIGGER knowledge_fts_update; DROP TABLE knowledge_fts; DROP TRIGGER knowledge_model_insert; DROP TRIGGER knowledge_model_update; DROP TRIGGER knowledge_model_delete; DROP TABLE knowledge_model_epoch; PRAGMA user_version=3"
            try removeAssignmentMigrationObjects(url)
            try sql(url, downgrade)
            let migrated = f.reopenedStore()
            let search = KnowledgeSearchService(store: migrated, meetingsRoot: f.root.appendingPathComponent("meetings"), documentsRoot: f.root.appendingPathComponent("copies"), queryEmbedding: { _ in throw LocalIndexingError.missingModel })
            #expect(try await search.search("релиз", scope: .all).hits.first?.source.key.externalID == id.uuidString)
            #expect(try await migrated.documents().first?.currentVersion.contentHash == f.store.documents().first?.currentVersion.contentHash)
            try removeAssignmentMigrationObjects(url)
            try sql(url, downgrade + "; CREATE TABLE knowledge_fts(sentinel TEXT); INSERT INTO knowledge_fts VALUES('keep')")
            let scope = try #require(SQLiteFixtureScope.current)
            await scope.expectingFailureOnNewConnection(at: url, phase: .prepare, operation: .create, result: 1, extended: 1) {
                await #expect(throws: ProjectStoreError.self) { try await f.reopenedStore().snapshot() }
            }
            var db: OpaquePointer?
            #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
            let connection = UUID(), rawScope = SQLiteFixtureScope.current
            if db != nil { rawScope?.observe(.opened(connection, url)) }
            defer { let result = sqlite3_close(db); if db != nil { rawScope?.observe(.closed(connection, result)) } }
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "SELECT sentinel FROM knowledge_fts", -1, &statement, nil) == SQLITE_OK)
            #expect(sqlite3_step(statement) == SQLITE_ROW)
            #expect(String(cString: sqlite3_column_text(statement, 0)) == "keep")
            sqlite3_finalize(statement)
            #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
            #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 3)
            sqlite3_finalize(statement)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func tamperedManagedCopyCannotOpenIndexedTextAsCurrent() async throws {
        let f = try Fixture()
        do {
            _ = try await f.document("Релиз утверждён")
            let search = f.service(), response = try await search.search("релиз", scope: .all)
            let hit = try #require(response.hits.first), version = try #require(hit.source.document)
            let file = try await f.importer.fileURL(for: version)
            let original = try Data(contentsOf: file)
            try Data("Подменённая копия документа".utf8).write(to: file, options: .atomic)
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(hit) }
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.search("релиз", scope: .all) }
            try original.write(to: file, options: .atomic)
            #expect(try await search.search("релиз", scope: .all).hits.count == 1)
            let mirror = f.root.appendingPathComponent("copies/mirror.txt")
            try original.write(to: mirror)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: mirror)
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.search("релиз", scope: .all) }
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func newUIRequestCancelsDelayedQueryWithoutPublishingItsOldResults() async throws {
        let f = try Fixture()
        do {
            _ = try await f.document("Релиз запланирован")
            _ = try await f.document("Машина на парковке")
            await f.indexer.start(); await f.indexer.waitUntilIdle()
            let entered = IndexGate(), release = IndexGate(), encoder = f.encoder
            let search = f.service(query: { text in
                if text == "Релиз" { await entered.signal(); await release.wait() }
                return try await encoder.embed([text], purpose: .query)[0]
            })
            f.resources.own(release)
            let model = f.model(service: search)
            model.query = "Релиз"; model.search()
            await entered.wait()
            model.query = "Машина"; model.search()
            let deadline = ContinuousClock.now + .seconds(5)
            while model.searching && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            await release.signal()
            #expect(!model.searching && model.error == nil)
            #expect(model.response?.hits.count == 1 && model.response?.hits.first?.chunk.text == "Машина на парковке")
            model.clear()
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func corruptVectorsAreReindexedAndLateRepairCannotResetNewGeneration() async throws {
        let f = try Fixture()
        do {
            _ = try await f.document("Релиз транспорт")
            await f.indexer.start(); await f.indexer.waitUntilIdle()
            let catalog = try await f.store.knowledgeSearchCatalog(scope: .all)
            let source = try #require(catalog.sources.first)
            try sql(f.root.appendingPathComponent("knowledge.sqlite"), "UPDATE embedding_vectors SET vector = zeroblob(length(vector))")
            await #expect(throws: KnowledgeSearchError.indexRepairing) { try await f.service().search("релиз", scope: .all) }
            await f.indexer.waitUntilIdle()
            let ready = try #require(try await f.store.embeddingJobs().first)
            #expect(ready.state == .ready && ready.generation != source.job.generation)
            #expect(try await f.service().search("релиз", scope: .all).hits.count == 1)
            #expect(try await f.store.reindexCorruptSearchSource(source, model: catalog.model) == false)
            #expect(try await f.store.embeddingJobs().first?.generation == ready.generation)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func malformedTranscriptIsReportedInItsScopeAfterBeingRemovedFromSearchCatalog() async throws {
        let f = try Fixture()
        do {
            let p = try await f.store.createProject(name: "Север"), q = try await f.store.createProject(name: "Лира")
            let file = try await f.meeting("bad", text: "Релиз")
            try await f.store.assignMeeting("bad", to: [p.id])
            try Data("{broken".utf8).write(to: file, options: .atomic)
            let indexer = f.indexer
            let search = KnowledgeSearchService(store: f.store, meetingsRoot: f.root.appendingPathComponent("meetings"), documentsRoot: f.root.appendingPathComponent("copies"),
                prepare: { try await indexer.synchronizeForSearch() }, queryEmbedding: { _ in throw LocalIndexingError.missingModel })
            let affected = try await search.search("релиз", scope: .project(p.id))
            #expect(affected.hits.isEmpty && affected.failedSources == 1)
            #expect(try await search.search("релиз", scope: .project(q.id)).failedSources == 0)
            #expect(try await search.search("релиз", scope: .inbox).failedSources == 0)
            try await f.store.assignMeeting("bad", to: [])
            #expect(try await search.search("релиз", scope: .inbox).failedSources == 1)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    private func sql(_ url: URL, _ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let connection = UUID(), scope = SQLiteFixtureScope.current
        scope?.observe(.opened(connection, url))
        defer { let result = sqlite3_close(db); scope?.observe(.closed(connection, result)) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor extension KnowledgeSearchTests {
    private enum SearchBodyError: Error { case sentinel }
    private func heldSearchBody(exit: String, scope: SQLiteFixtureScope, witness: SearchIndexFixtureWitness,
                                entered: IndexGate, release: IndexGate, tail: IndexGate) async throws {
        let f = try Fixture()
        witness.root = f.root; witness.store = f.store; witness.indexer = f.indexer; witness.resources = f.resources
        f.resources.own(release)
        _ = try await f.document("Релиз транспорт")
        await f.indexer.start(); await f.indexer.waitUntilIdle()
        let reopened = f.reopenedStore()
        #expect(try await reopened.documents().count == 1)
        let store = f.store, root = f.root, encoder = f.encoder
        let search = f.service(query: { text in
            await entered.signal(); await release.wait()
            scope.note("search-index-late-write-enter")
            #expect(FileManager.default.fileExists(atPath: root.path))
            _ = try await store.createProject(name: "Synthetic held search late write")
            #expect(try await store.snapshot().projects.count == 1)
            scope.note("search-index-late-write-finished")
            await tail.wait()
            scope.note("search-held-query-returned")
            return try await encoder.embed([text], purpose: .query)[0]
        })
        let model = f.model(service: search)
        witness.search = search; witness.model = model
        model.query = "релиз"; model.search(); await entered.wait()
        if exit == "cancel" { withUnsafeCurrentTask { $0?.cancel() }; try Task.checkCancellation() }
        if exit == "throw" { throw SearchBodyError.sentinel }
    }
    @Test(arguments: ["return", "throw", "cancel"]) func heldSearchModelAndLateWriteDrainAfterEveryBodyExit(exit: String) async throws {
        let scope = SQLiteFixtureScope(test: "held-search-\(exit)"), witness = SearchIndexFixtureWitness()
        let entered = IndexGate(), release = IndexGate(), tail = IndexGate()
        try await SQLiteFixtureScope.$current.withValue(scope) {
            try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
                let body = await Task { () -> Result<Void, any Error> in
                    do { try await heldSearchBody(exit: exit, scope: scope, witness: witness, entered: entered, release: release, tail: tail); return .success(()) }
                    catch { return .failure(error) }
                }.value
                let root = try #require(witness.root)
                let cleanup = Task { try await scope.finish() }
                let deadline = ContinuousClock.now + .seconds(3)
                while !scope.trace.contains(where: { $0["stage"] == "search-index-late-write-finished" }), ContinuousClock.now < deadline { await Task.yield() }
                #expect(scope.trace.contains { $0["stage"] == "search-index-late-write-finished" })
                #expect(witness.model != nil && witness.model?.searching == false && witness.model?.response == nil)
                #expect(FileManager.default.fileExists(atPath: root.path))
                #expect(!scope.trace.contains { $0["stage"] == "root-removed" })
                #expect(scope.trace.filter { $0["stage"] == "closed" }.count == 1)
                await tail.signal(); try await cleanup.value
                #expect(witness.model == nil && witness.search == nil && witness.indexer == nil && witness.store == nil)
                #expect(scope.trace.filter { $0["stage"] == "closed" && $0["result"] == "0" }.count == 2)
                #expect(!FileManager.default.fileExists(atPath: root.path))
                #expect(!scope.trace.contains { $0["stage"] == "sqlite-failure" })
                if exit == "cancel" { #expect(throws: CancellationError.self) { try body.get() } }
                else if exit == "throw" { #expect(throws: SearchBodyError.sentinel) { try body.get() } }
                else { try body.get() }
            }
        }
    }
}
