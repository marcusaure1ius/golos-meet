import Foundation
import Testing
@testable import golos_meet

/// Production worker/SQLite/reader with tiny lifecycle vectors, not real E5.
@MainActor @Suite struct MeetingAssignmentRuntimeTests {
    private struct Fixture {
        let root: URL
        let store: ProjectStore
        let indexer: LocalIndexingService
        let projects: ProjectLibrary
        let engine: MeetingAssignmentService
        let worker: MeetingAssignmentWorker
        var meetings: URL { root.appendingPathComponent("meetings") }
        var copies: URL { root.appendingPathComponent("copies") }
        var database: URL { root.appendingPathComponent("knowledge.sqlite") }
        @MainActor init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("assignment-runtime-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
            projects = ProjectLibrary(store: store)
            let encoder = LifecycleEncoder(id: "assignment-runtime-fixture")
            indexer = LocalIndexingService(store: store, meetingsRoot: root.appendingPathComponent("meetings"), inspect: {
                .init(model: .init(id: encoder.modelID, dimensions: 2), folder: nil, load: { encoder })
            })
            engine = MeetingAssignmentService(store: store, meetingsRoot: root.appendingPathComponent("meetings"), documentsRoot: root.appendingPathComponent("copies"))
            worker = MeetingAssignmentWorker(store: store, meetingsRoot: root.appendingPathComponent("meetings"), documentsRoot: root.appendingPathComponent("copies"), indexAvailable: true)
        }
        @discardableResult func seed() async throws -> KnowledgeProject {
            let p = try await store.createProject(name: "Янтарь")
            let file = root.appendingPathComponent("План.txt")
            try Data("Янтарь: переносим складской учёт и проверяем обмен с кассами.".utf8).write(to: file)
            _ = try await DocumentImporter(store: store, root: copies).importFile(id: UUID(), url: file, projectIDs: [p.id]) { _ in }
            try await meeting("a")
            await indexer.start(); await indexer.waitUntilIdle()
            await projects.reload()
            return p
        }
        @discardableResult func meeting(_ id: String, text: String = "Янтарь: переносим складской учёт и проверяем обмен с кассами.") async throws -> URL {
            let folder = meetings.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("transcript.json")
            try JSONSerialization.data(withJSONObject: ["meetingId": id, "segments": [["start": 12, "end": 30, "text": text]]]).write(to: file, options: .atomic)
            _ = try await MeetingEmbeddingSnapshotReader(root: meetings).synchronize(meetingID: id, store: store)
            return file
        }
        func cleanup() async { await worker.stop(); await worker.waitUntilIdle(); await indexer.stop(); try? FileManager.default.removeItem(at: root) }
    }

    @Test func readyIndexIsAutomaticallyAssignedWithoutMeetingScreenAndStaleLinksAreRemovedUntilRecovery() async throws {
        let f = try Fixture()
        do {
            let p = try await f.seed()
            await f.worker.start(); await f.worker.waitUntilIdle()
            #expect(try await f.store.snapshot().meetingProjects["a"] == [p.id])
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .current)
            try await f.store.requestEmbeddingReindex(.init(kind: .meeting, externalID: "a"))
            await f.worker.changed(); await f.worker.waitUntilIdle()
            #expect(try await f.store.snapshot().meetingProjects["a"] == nil)
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .waiting)
            await f.indexer.changed(); await f.indexer.waitUntilIdle()
            await f.worker.changed(); await f.worker.waitUntilIdle()
            #expect(try await f.store.snapshot().meetingProjects["a"] == [p.id])
            let current = try await f.store.assignmentRuntimeSnapshot()
            await f.worker.changed(); await f.worker.waitUntilIdle()
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"] == current.work["a"])
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func cancellationSurvivesRestartAndLateNoncooperativePublisherCannotRestoreLinks() async throws {
        let f = try Fixture()
        let entered = IndexGate(), release = IndexGate()
        let blocked = MeetingAssignmentWorker(store: f.store, meetingsRoot: f.meetings, documentsRoot: f.copies, indexAvailable: true, calculate: { id, lease in
            let plan = try await f.engine.prepare(meetingID: id)!
            await entered.signal(); await release.wait()
            // Intentionally bypass cooperative Task cancellation in this fixture.
            return try await f.store.commitMeetingAssignment(plan.result, meetingID: id, checkpoint: plan.checkpoint, runtimeLease: lease)
        })
        do {
            _ = try await f.seed()
            await blocked.start(); await entered.wait()
            await blocked.cancel("a")
            await release.signal(); await blocked.waitUntilIdle(); await blocked.stop()
            #expect(try await f.store.snapshot().meetingProjects["a"] == nil)
            let restarted = MeetingAssignmentWorker(store: ProjectStore(url: f.database), meetingsRoot: f.meetings, documentsRoot: f.copies, indexAvailable: true)
            await restarted.start(); await restarted.waitUntilIdle()
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .cancelled)
            await restarted.retry("a"); await restarted.waitUntilIdle()
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .current)
            await restarted.stop()
        } catch { await release.signal(); await blocked.stop(); await blocked.waitUntilIdle(); await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func stopRestartDoesNotOverlapOldCalculationAndManualInboxWinsItsLateResult() async throws {
        let f = try Fixture(), entered = IndexGate(), release = IndexGate()
        let blocked = MeetingAssignmentWorker(store: f.store, meetingsRoot: f.meetings, documentsRoot: f.copies, indexAvailable: true, calculate: { id, lease in
            let plan = try await f.engine.prepare(meetingID: id)!
            await entered.signal(); await release.wait()
            return try await f.store.commitMeetingAssignment(plan.result, meetingID: id, checkpoint: plan.checkpoint, runtimeLease: lease)
        })
        do {
            _ = try await f.seed()
            await blocked.start(); await entered.wait(); await blocked.stop()
            try await f.store.assignMeeting("a", to: [])
            await blocked.start(); await release.signal(); await blocked.waitUntilIdle()
            #expect(try await f.store.snapshot().meetingProjects["a"] == nil)
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .manual)
            await blocked.stop()
        } catch { await release.signal(); await blocked.stop(); await blocked.waitUntilIdle(); await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func failureDoesNotStarveFollowingMeetingsAndChangedSourceAutomaticallyRetries() async throws {
        let f = try Fixture()
        do {
            _ = try await f.seed()
            try await f.meeting("b")
            await f.indexer.changed(); await f.indexer.waitUntilIdle()
            try Data("broken".utf8).write(to: f.meetings.appendingPathComponent("a/transcript.json"))
            await f.worker.start(); await f.worker.waitUntilIdle()
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .failed)
            #expect(try await f.store.assignmentRuntimeSnapshot().work["b"]?.state == .current)
            try await f.meeting("a")
            await f.indexer.changed(); await f.indexer.waitUntilIdle()
            await f.worker.changed(); await f.worker.waitUntilIdle()
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .current)
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func unrelatedIndexCompletionAutomaticallyRetriesSupersededPlanWithoutUserAction() async throws {
        let f = try Fixture(), entered = IndexGate(), release = IndexGate()
        let worker = MeetingAssignmentWorker(store: f.store, meetingsRoot: f.meetings, documentsRoot: f.copies, indexAvailable: true, calculate: { id, lease in
            guard let plan = try await f.engine.prepare(meetingID: id) else { return .manual }
            if id == "a" { await entered.signal(); await release.wait() }
            return try await f.engine.commit(plan, runtimeLease: lease)
        })
        do {
            _ = try await f.seed(); try await f.meeting("z")
            await worker.start(); await entered.wait()
            await f.indexer.changed(); await f.indexer.waitUntilIdle()
            await worker.changed() // Same hook used by the production index stream.
            await release.signal(); await worker.waitUntilIdle()
            let state = try await f.store.assignmentRuntimeSnapshot()
            #expect(state.work["a"]?.state == .current && state.work["z"]?.state == .current)
            await worker.stop()
        } catch { await release.signal(); await worker.stop(); await worker.waitUntilIdle(); await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func missingRuntimeRemovesAutomaticLinksAndRecoverySchedulesSameReadyVectorsAgain() async throws {
        let f = try Fixture()
        do {
            let p = try await f.seed()
            await f.worker.start(); await f.worker.waitUntilIdle()
            #expect(try await f.store.snapshot().meetingProjects["a"] == [p.id])
            await f.worker.setIndexAvailable(false); await f.worker.waitUntilIdle()
            #expect(try await f.store.snapshot().meetingProjects["a"] == nil)
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .waiting)
            await f.worker.setIndexAvailable(true); await f.worker.waitUntilIdle()
            #expect(try await f.store.snapshot().meetingProjects["a"] == [p.id])
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func deadlineFencesAnUncooperativeCalculationBeforeRetry() async throws {
        let f = try Fixture(), entered = IndexGate(), release = IndexGate()
        var blocked: MeetingAssignmentWorker?
        do {
            _ = try await f.seed()
            // Prepare before starting the test deadline, so even an overloaded
            // executor cannot cancel preparation before the fixture gate opens.
            let plan = try #require(try await f.engine.prepare(meetingID: "a"))
            let current = MeetingAssignmentWorker(store: f.store, meetingsRoot: f.meetings, documentsRoot: f.copies,
                indexAvailable: true, timeout: .milliseconds(20), calculate: { id, lease in
                    await entered.signal(); await release.wait()
                    // Detached context proves the durable fence, independently
                    // of the cancelled task's cooperative checks.
                    return try await Task.detached {
                        try await f.store.commitMeetingAssignment(plan.result, meetingID: id, checkpoint: plan.checkpoint, runtimeLease: lease)
                    }.value
                })
            blocked = current
            await current.start(); await entered.wait()
            try await wait { try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .failed }
            await release.signal(); await current.waitUntilIdle()
            #expect(try await f.store.snapshot().meetingProjects["a"] == nil)
            await current.stop()
            await f.worker.start(); await f.worker.waitUntilIdle()
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .failed)
            await f.worker.retry("a"); await f.worker.waitUntilIdle()
            #expect(try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .current)
        } catch { await release.signal(); await blocked?.stop(); await blocked?.waitUntilIdle(); await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test(arguments: ["reindex", "manual", "modelABA", "fileABA", "scope"])
    func openingSavedEvidenceRequiresCurrentRuntimeAndBothSourceRevisions(change: String) async throws {
        let f = try Fixture()
        do {
            let p = try await f.seed()
            await f.worker.start(); await f.worker.waitUntilIdle()
            let reader = MeetingAssignmentEvidenceReader(store: f.store, meetingsRoot: f.meetings, documentsRoot: f.copies)
            #expect(try await reader.open(meetingID: "a", projectID: p.id, context: false).hit.chunk.location.startSeconds == 12)
            #expect(try await reader.open(meetingID: "a", projectID: p.id, context: true).chunks.first?.text.contains("Янтарь") == true)
            switch change {
            case "reindex": try await f.store.requestEmbeddingReindex(.init(kind: .meeting, externalID: "a"))
            case "manual": try await f.store.assignMeeting("a", to: [])
            case "modelABA":
                try await f.store.activateEmbeddingModel(.init(id: "replacement", dimensions: 2))
                try await f.store.activateEmbeddingModel(.init(id: "assignment-runtime-fixture", dimensions: 2))
            case "fileABA":
                let file = f.meetings.appendingPathComponent("a/transcript.json"), bytes = try Data(contentsOf: file)
                try Data("broken".utf8).write(to: file); try bytes.write(to: file)
            default:
                try ProjectDatabase(url: f.database).execute("DELETE FROM document_projects WHERE project_id=?", bindings: [p.id.uuidString])
            }
            await #expect(throws: (any Error).self) { try await reader.open(meetingID: "a", projectID: p.id, context: true) }
        } catch { await f.cleanup(); throw error }
        await f.cleanup()
    }

    @Test func indexUpdateBridgeRunsWhileNoScreenIsOpenAndManualEventsDoNotReindex() async throws {
        let f = try Fixture()
        let bridge = KnowledgeAssignments(store: f.store, projects: f.projects, indexing: f.indexer,
            meetingsRoot: f.meetings, documentsRoot: f.copies, center: .default)
        do {
            let p = try await f.seed()
            bridge.start()
            let generations = try await f.store.embeddingJobs().map(\.generation)
            try await wait {
                guard try await f.store.assignmentRuntimeSnapshot().work["a"]?.state == .current,
                      f.projects.projectIDs(for: "a") == [p.id], f.projects.isReady else { return false }
                #expect(f.projects.projectIDs(for: "a") == [p.id])
                // Check readiness and enter assign in the same MainActor turn.
                // Returning from wait first lets an unrelated .projects event
                // start a reload between this check and the assignment guard.
                try await f.projects.assign(meetingID: "a", projectIDs: [])
                return true
            }
            try await wait { bridge.snapshot.work["a"]?.state == .manual }
            #expect(try await f.store.embeddingJobs().map(\.generation) == generations)
            #expect(f.projects.projectIDs(for: "a").isEmpty)
        } catch { bridge.stop(); await f.cleanup(); throw error }
        bridge.stop(); await f.cleanup()
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<400 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Runtime state did not arrive within four seconds")
    }
}
