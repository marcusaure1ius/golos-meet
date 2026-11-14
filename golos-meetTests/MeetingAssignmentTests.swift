import Foundation
import Testing
@testable import golos_meet

/// Deliberately synthetic: lifecycle/transaction tests, not semantic quality.
private actor AssignmentFixtureEncoder: LocalPassageEmbedding {
    nonisolated let modelID = "assignment-fixture"
    nonisolated let dimensions = 2
    func embed(_ texts: [String], purpose: EmbeddingPurpose) throws -> [KnowledgeVector] {
        try texts.map { try KnowledgeVector(modelID: modelID, values: $0.contains("Спутник") ? [0, 1] : [1, 0]) }
    }
    func passageWindows(_ text: String) throws -> [EmbeddedPassageWindow] {
        [.init(tokenStart: 0, tokenCount: 5, vector: try embed([text], purpose: .passage)[0])]
    }
}

@MainActor @Suite(SQLiteFixtureTrait()) struct MeetingAssignmentTests {
    private struct Fixture {
        let root: URL
        let store: ProjectStore
        let indexer: LocalIndexingService
        let importer: DocumentImporter
        let service: MeetingAssignmentService
        let encoder = AssignmentFixtureEncoder()
        var url: URL { root.appendingPathComponent("knowledge.sqlite") }
        init(budget: Int = 2_000, comparisons: Int = 100_000, inspect: LocalIndexingService.Inspector? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("assignment-fixture-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            SQLiteFixtureScope.current?.register(root: root)
            store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
            SQLiteFixtureScope.current?.register(store: store)
            importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
            service = MeetingAssignmentService(store: store, meetingsRoot: root.appendingPathComponent("meetings"), documentsRoot: root.appendingPathComponent("copies"), windowBudget: budget, comparisonBudget: comparisons)
            let encoder = self.encoder
            indexer = LocalIndexingService(store: store, meetingsRoot: root.appendingPathComponent("meetings"), inspect: inspect ?? {
                .init(model: .init(id: encoder.modelID, dimensions: encoder.dimensions), folder: nil, load: { encoder })
            })
            if let scope = SQLiteFixtureScope.current {
                let indexer = self.indexer
                scope.onFinish { [weak indexer, weak scope] in
                    guard let indexer else { return }
                    scope?.note("assignment-indexer-stop-requested")
                    await indexer.stop(); await indexer.waitUntilIdle()
                    scope?.note("assignment-indexer-stopped")
                }
            }
        }
        func reopenedStore() -> ProjectStore {
            let reopened = ProjectStore(url: url)
            SQLiteFixtureScope.current?.register(store: reopened)
            return reopened
        }
        func document(_ text: String, project: UUID) async throws {
            let file = root.appendingPathComponent("\(UUID()).txt")
            try Data(text.utf8).write(to: file)
            _ = try await importer.importFile(id: UUID(), url: file, projectIDs: [project]) { _ in }
        }
        @discardableResult func meeting(_ id: String = "target", texts: [String] = ["Атлас: строим мост через реку."]) async throws -> URL {
            let folder = root.appendingPathComponent("meetings/\(id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("transcript.json")
            let segments = texts.enumerated().map { ["text": $0.element, "start": Double($0.offset * 20), "end": Double($0.offset * 20 + 10)] as [String: Any] }
            try JSONSerialization.data(withJSONObject: ["meetingId": id, "segments": segments]).write(to: file, options: .atomic)
            _ = try await MeetingEmbeddingSnapshotReader(root: root.appendingPathComponent("meetings")).synchronize(meetingID: id, store: store)
            return file
        }
        func seed() async throws -> KnowledgeProject {
            let p = try await store.createProject(name: "Атлас")
            try await document("Атлас: строим мост через реку.", project: p.id)
            try await meeting()
            await indexer.start(); await indexer.waitUntilIdle()
            return p
        }
        func cleanup() async {
            SQLiteFixtureScope.current?.note("assignment-indexer-stop-requested")
            await indexer.stop(); await indexer.waitUntilIdle()
            SQLiteFixtureScope.current?.note("assignment-indexer-stopped")
        }
    }

    @Test func automaticManyToManyPersistsAndRepeatingSameCalculationDoesNotChurnEpoch() async throws {
        let f = try Fixture()
        do {
            let a = try await f.seed(), b = try await f.store.createProject(name: "Спутник")
            try await f.document("Спутник: строим сеть передачи данных.", project: b.id)
            try await f.meeting(texts: ["Атлас: строим мост через реку.", "Спутник: строим сеть передачи данных."])
            await f.indexer.changed(); await f.indexer.waitUntilIdle()
            let plan = try #require(try await f.service.prepare(meetingID: "target"))
            #expect(plan.result.assignedProjectIDs == [a.id, b.id])
            #expect(try await f.service.commit(plan) == .applied)
            let reopened = f.reopenedStore()
            #expect(try await reopened.snapshot().meetingProjects["target"] == [a.id, b.id])
            #expect(try await reopened.meetingAssignmentCheckpoint().decisions["target"]?.origin == .automatic)
            let again = try #require(try await f.service.prepare(meetingID: "target"))
            #expect(try await f.service.commit(again) == .unchanged)
            #expect(try await f.store.meetingAssignmentCheckpoint().epoch == again.checkpoint.epoch)
            #expect(try await f.store.documents().count == 2) // No source copies.
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test(arguments: [false, true]) func manualSelectionIncludingInboxFencesAlreadyPreparedPlanAndSurvivesRestart(empty: Bool) async throws {
        let f = try Fixture()
        do {
            let p = try await f.seed()
            let plan = try #require(try await f.service.prepare(meetingID: "target"))
            let selection: Set<UUID> = empty ? [] : [p.id]
            try await f.store.assignMeeting("target", to: selection)
            // The store's transaction independently protects against a delayed
            // caller even if the caller bypasses service-side validation.
            #expect(try await f.store.commitMeetingAssignment(plan.result, meetingID: "target", checkpoint: plan.checkpoint) == .manual)
            await #expect(throws: (any Error).self) { try await f.service.commit(plan) }
            try await f.store.requestEmbeddingReindex(.init(kind: .meeting, externalID: "target"))
            await f.indexer.changed(); await f.indexer.waitUntilIdle()
            let restarted = f.reopenedStore()
            #expect(try await restarted.snapshot().meetingProjects["target"] ?? [] == selection)
            #expect(try await restarted.meetingAssignmentCheckpoint().decisions["target"]?.origin == .manual)
            #expect(try await f.service.prepare(meetingID: "target") == nil)
            try await f.store.activateEmbeddingModel(.init(id: "replacement", dimensions: 2))
            #expect(try await restarted.meetingAssignmentCheckpoint().decisions["target"]?.origin == .manual)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test(arguments: ["projectABA", "modelABA", "reindex", "recreate", "fileABA", "contextFile", "deleteProject", "manualABA"])
    func latePlansCannotOverwriteChangedContext(change: String) async throws {
        let f = try Fixture()
        do {
            let p = try await f.seed()
            let plan = try #require(try await f.service.prepare(meetingID: "target"))
            let key = EmbeddingSourceKey(kind: .meeting, externalID: "target")
            switch change {
            case "projectABA":
                let db = try ProjectDatabase(url: f.url)
                try db.execute("UPDATE projects SET name='Другое' WHERE id=?", bindings: [p.id.uuidString])
                try db.execute("UPDATE projects SET name='Атлас' WHERE id=?", bindings: [p.id.uuidString])
            case "modelABA":
                try await f.store.activateEmbeddingModel(.init(id: "replacement", dimensions: 2))
                try await f.store.activateEmbeddingModel(.init(id: f.encoder.modelID, dimensions: 2))
            case "reindex": try await f.store.requestEmbeddingReindex(key)
            case "recreate":
                try await f.store.removeEmbeddingSource(key)
                try await f.meeting()
            case "fileABA":
                let file = f.root.appendingPathComponent("meetings/target/transcript.json")
                let data = try Data(contentsOf: file)
                try Data("broken".utf8).write(to: file)
                try data.write(to: file)
            case "contextFile":
                let version = try #require(try await f.store.documents().first?.currentVersion)
                let file = try await f.importer.fileURL(for: version)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                try Data("Подмена контекста".utf8).write(to: file)
            case "deleteProject":
                let db = try ProjectDatabase(url: f.url)
                try db.execute("DELETE FROM document_projects WHERE project_id=?", bindings: [p.id.uuidString])
                try db.execute("DELETE FROM projects WHERE id=?", bindings: [p.id.uuidString])
            default:
                try await f.store.assignMeeting("target", to: [p.id])
                try await f.store.assignMeeting("target", to: [])
            }
            await #expect(throws: (any Error).self) { try await f.service.commit(plan) }
            #expect(try await f.store.snapshot().meetingProjects["target"] == nil)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func ambiguousNamesAndGenericMatchesAreProposalsNotAutomaticContext() async throws {
        let f = try Fixture()
        do {
            let p = try await f.seed()
            _ = try await f.store.createProject(name: "Атлас")
            let ambiguous = try #require(try await f.service.prepare(meetingID: "target"))
            #expect(ambiguous.result.assignedProjectIDs.isEmpty && !ambiguous.result.evidence.isEmpty)
            #expect(try await f.service.commit(ambiguous) == .applied)
            #expect(try await f.store.meetingAssignmentCheckpoint().decisions["target"]?.origin == .proposal)
            try await f.meeting("negative", texts: ["Атлас не относится к этой встрече."])
            try await f.meeting("topic", texts: ["Обсудили новый бюджет и построили планы."])
            await f.indexer.changed(); await f.indexer.waitUntilIdle()
            #expect(try await f.service.prepare(meetingID: "negative")?.result.assignedProjectIDs.isEmpty == true)
            #expect(try await f.service.prepare(meetingID: "topic")?.result.assignedProjectIDs.isEmpty == true)
            // Remove trusted context: previously proposed/auto meetings cannot
            // manufacture their own project context for another assignment.
            let db = try ProjectDatabase(url: f.url)
            try db.execute("DELETE FROM document_projects WHERE project_id=?", bindings: [p.id.uuidString])
            let unanchored = try #require(try await f.service.prepare(meetingID: "topic"))
            #expect(unanchored.result.evidence.isEmpty && unanchored.result.suggestedTopic != nil)
            #expect(try await f.store.snapshot().projects.count == 2) // Never creates projects.
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test(arguments: ["Без имени", "ИИ", "Переименованный проект"])
    func semanticEvidenceDoesNotRequireProjectNameAndSurvivesRename(name: String) async throws {
        let f = try Fixture()
        do {
            let p = try await f.store.createProject(name: name)
            try await f.document("Датчики давления и пульса передают тревоги врачу в медицинскую карту.", project: p.id)
            try await f.meeting(texts: ["Врач проверяет давление, пульс и тревоги датчиков в медицинской карте."])
            await f.indexer.start(); await f.indexer.waitUntilIdle()
            let plan = try #require(try await f.service.prepare(meetingID: "target"))
            #expect(plan.result.assignedProjectIDs == [p.id])
            #expect(plan.result.evidence.first?.explicitName == false)
            #expect((plan.result.evidence.first?.support?.distinctiveTerms.count ?? 0) >= 2)
            #expect(try await f.service.commit(plan) == .applied)
            try ProjectDatabase(url: f.url).execute("UPDATE projects SET name=? WHERE id=?", bindings: ["Совсем новое название", p.id.uuidString])
            let renamed = try #require(try await f.service.prepare(meetingID: "target"))
            #expect(renamed.result.assignedProjectIDs == [p.id])
            #expect(try await f.service.commit(renamed) == .applied)
            try await f.store.assignMeeting("target", to: [])
            let reopened = f.reopenedStore()
            #expect(try await reopened.meetingAssignmentCheckpoint().decisions["target"]?.origin == .manual)
            #expect(try await f.service.prepare(meetingID: "target") == nil)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func negatedSeparateChunkCannotBeOverriddenByTemptingPositiveEvidence() async throws {
        let f = try Fixture()
        do {
            _ = try await f.seed()
            try await f.meeting(texts: ["Атлас: строим мост через реку.", "Этот проект не относится к нашей встрече."])
            await f.indexer.changed(); await f.indexer.waitUntilIdle()
            let plan = try #require(try await f.service.prepare(meetingID: "target"))
            #expect(plan.result.assignedProjectIDs.isEmpty)
            #expect(plan.result.evidence.allSatisfy { $0.support?.blocked == true })
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func oldPayloadDecodesButCannotPublishUnderNewPolicy() async throws {
        let f = try Fixture()
        do {
            _ = try await f.seed()
            let plan = try #require(try await f.service.prepare(meetingID: "target"))
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan.result)) as? [String: Any])
            json["algorithm"] = "explicit-name-margin-e5-v2"
            var evidence = try #require(json["evidence"] as? [[String: Any]])
            for i in evidence.indices { evidence[i].removeValue(forKey: "support") }
            json["evidence"] = evidence
            let old = try JSONDecoder().decode(MeetingAssignmentResult.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(old.evidence.allSatisfy { $0.support == nil })
            await #expect(throws: MeetingAssignmentError.self) {
                try await f.store.commitMeetingAssignment(old, meetingID: "target", checkpoint: plan.checkpoint)
            }
            #expect(try await f.store.snapshot().meetingProjects["target"] == nil)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func lexicalPreparationCannotPublishAConfidentPartialResultOverBudget() async throws {
        let f = try Fixture(comparisons: 1)
        do {
            _ = try await f.seed()
            await #expect(throws: MeetingAssignmentError.self) { try await f.service.prepare(meetingID: "target") }
            #expect(try await f.store.meetingAssignmentCheckpoint().decisions["target"] == nil)
            #expect(try await f.store.snapshot().meetingProjects["target"] == nil)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func automaticAssignmentsDoNotTrainOtherMeetingsButExplicitManualContextDoes() async throws {
        let f = try Fixture()
        do {
            let p = try await f.seed()
            let first = try #require(try await f.service.prepare(meetingID: "target"))
            #expect(try await f.service.commit(first) == .applied)
            try await f.meeting("second")
            await f.indexer.changed(); await f.indexer.waitUntilIdle()
            let db = try ProjectDatabase(url: f.url)
            try db.execute("DELETE FROM document_projects WHERE project_id=?", bindings: [p.id.uuidString])
            let withoutContext = try #require(try await f.service.prepare(meetingID: "second"))
            #expect(withoutContext.result.evidence.isEmpty && withoutContext.result.assignedProjectIDs.isEmpty)
            try await f.store.assignMeeting("target", to: [p.id])
            let manualContext = try #require(try await f.service.prepare(meetingID: "second"))
            #expect(manualContext.result.assignedProjectIDs == [p.id])
            #expect(manualContext.result.evidence.first?.contextSource == .init(kind: .meeting, externalID: "target"))
            #expect(try await f.service.commit(manualContext) == .applied)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func cancellationAndInvalidTranscriptCannotPublishAnyDecision() async throws {
        let f = try Fixture()
        do {
            _ = try await f.seed()
            let plan = try #require(try await f.service.prepare(meetingID: "target"))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.service.commit(plan)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await f.store.meetingAssignmentCheckpoint().decisions["target"] == nil)
            try Data("broken json".utf8).write(to: f.root.appendingPathComponent("meetings/target/transcript.json"))
            await #expect(throws: (any Error).self) { try await f.service.prepare(meetingID: "target") }
            #expect(try await f.store.meetingAssignmentCheckpoint().decisions["target"] == nil)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func unavailableCancelledAndOverBudgetIndexesDoNotWriteAssignments() async throws {
        let f = try Fixture(budget: 0)
        do {
            _ = try await f.seed()
            await #expect(throws: MeetingAssignmentError.self) { try await f.service.prepare(meetingID: "target") }
            try await f.store.cancelEmbeddingJob(.init(kind: .meeting, externalID: "target"))
            await #expect(throws: MeetingAssignmentError.self) { try await f.service.prepare(meetingID: "target") }
            #expect(try await f.store.meetingAssignmentCheckpoint().decisions["target"] == nil)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func missingTrustedContextIsAnExplicitErrorInsteadOfSilentlyReducingCompetition() async throws {
        let f = try Fixture()
        do {
            let p = try await f.seed()
            try await f.store.assignMeeting("missing-transcript", to: [p.id])
            await f.indexer.changed(); await f.indexer.waitUntilIdle()
            await #expect(throws: MeetingAssignmentError.self) { try await f.service.prepare(meetingID: "target") }
            #expect(try await f.store.meetingAssignmentCheckpoint().decisions["target"] == nil)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func v4MigrationPreservesExplicitInboxAndMultipleOwnersAndRollsBackFailure() async throws {
        let f = try Fixture()
        do {
            let a = try await f.seed(), b = try await f.store.createProject(name: "Второй")
            try await f.store.assignMeeting("target", to: [a.id, b.id])
            try await f.store.assignMeeting("inbox", to: [])
            try removeAssignmentMigrationObjects(f.url)
            let db = try ProjectDatabase(url: f.url)
            try db.execute("PRAGMA user_version=4")
            try db.execute("CREATE TABLE meeting_decisions_v5(sentinel TEXT)")
            try db.execute("INSERT INTO meeting_decisions_v5 VALUES ('keep')")
            let scope = try #require(SQLiteFixtureScope.current)
            await scope.expectingFailureOnNewConnection(at: f.url, phase: .prepare, operation: .create, result: 1, extended: 1) {
                await #expect(throws: ProjectStoreError.self) { try await f.reopenedStore().snapshot() }
            }
            #expect(try db.rows("PRAGMA user_version") == [["4"]])
            #expect(try db.rows("SELECT sentinel FROM meeting_decisions_v5") == [["keep"]])
            try db.execute("DROP TABLE meeting_decisions_v5")
            let restarted = f.reopenedStore()
            #expect(try await restarted.snapshot().meetingProjects["target"] == [a.id, b.id])
            let checkpoint = try await restarted.meetingAssignmentCheckpoint()
            #expect(checkpoint.decisions["inbox"]?.origin == .manual && checkpoint.decisions["target"]?.origin == .manual)
            #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
            #expect(try await restarted.documents().count == 1)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }
}

@MainActor extension MeetingAssignmentTests {
    private enum FixtureBodyError: Error { case sentinel }
    private func interruptedFixtureBody(scope: SQLiteFixtureScope, entered: IndexGate, release: IndexGate, cancel: Bool) async throws {
        let f = try Fixture(inspect: {
            await entered.signal(); await release.wait()
            return nil
        })
        _ = try await f.store.createProject(name: "Synthetic lifecycle")
        let reopened = f.reopenedStore()
        #expect(try await reopened.snapshot().projects.count == 1)
        await f.indexer.start(); await entered.wait()
        // Leave an actually suspended index worker behind on either exit path.
        // The scope's weak cleanup request must stop/join it after this body exits.
        if cancel { withUnsafeCurrentTask { $0?.cancel() }; try Task.checkCancellation() }
        throw FixtureBodyError.sentinel
    }
    @Test(arguments: [false, true]) func fixtureThrowAndCancellationDrainSuspendedIndexerBeforeNativeCloseAndUnlink(cancel: Bool) async throws {
        let scope = SQLiteFixtureScope(test: "assignment-interrupted-body"), entered = IndexGate(), release = IndexGate()
        try await SQLiteFixtureScope.$current.withValue(scope) {
            try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
                let body = await Task { () -> Result<Void, any Error> in
                    do { try await interruptedFixtureBody(scope: scope, entered: entered, release: release, cancel: cancel); return .success(()) }
                    catch { return .failure(error) }
                }.value
                let rootName = try #require(scope.trace.first { $0["stage"] == "root-owned" }?["root"])
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(rootName)
                let cleanup = Task { try await scope.finish() }
                let deadline = ContinuousClock.now + .seconds(3)
                while !scope.trace.contains(where: { $0["stage"] == "assignment-indexer-stop-requested" }), ContinuousClock.now < deadline { await Task.yield() }
                #expect(scope.trace.contains { $0["stage"] == "assignment-indexer-stop-requested" })
                #expect(FileManager.default.fileExists(atPath: root.path))
                #expect(!scope.trace.contains { $0["stage"] == "root-removed" })
                // One reopened store has closed, but the suspended worker still
                // owns the primary store. No native force-close is available.
                #expect(scope.trace.filter { $0["stage"] == "opened" }.count == 2)
                #expect(scope.trace.filter { $0["stage"] == "closed" }.count == 1)
                await release.signal(); try await cleanup.value
                #expect(FileManager.default.fileExists(atPath: root.path) == false)
                #expect(scope.trace.filter { $0["stage"] == "closed" && $0["result"] == "0" }.count == 2)
                #expect(!scope.trace.contains { $0["stage"] == "sqlite-failure" })
                if cancel { #expect(throws: CancellationError.self) { try body.get() } }
                else { #expect(throws: FixtureBodyError.sentinel) { try body.get() } }
            }
        }
    }
}
