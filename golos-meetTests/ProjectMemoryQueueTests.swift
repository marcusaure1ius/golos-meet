import Foundation
import Combine
import Testing
@testable import golos_meet

@MainActor private final class QueueFixture {
    let base: UpdateFixture
    let worker: ProjectMemoryQueueWorker
    var payloads: [String] = []
    var onCall: ((Int) async throws -> Void)?
    var insufficient = false
    init(timeout: Duration = .seconds(30), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        base = try UpdateFixture()
        worker = ProjectMemoryQueueWorker(store: base.store, meetingsRoot: base.root.appendingPathComponent("meetings"), documentsRoot: base.root.appendingPathComponent("copies"), client: base.spy, model: "fake-only", timeout: timeout, sleep: sleep)
        base.spy.afterAttempt = { [weak self] _ in
            guard let self else { return }
            payloads.append(base.spy.payload)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(base.spy.payload.utf8)) as? [String:Any])
            let fragments = try #require(object["fragments"] as? [[String:Any]])
            let facts = try fragments.map { fragment -> [String:Any] in
                let text = try #require(fragment["text"] as? String), label = try #require(fragment["label"] as? String)
                return ["subject": "fact:" + MemoryEncoding.hash(text), "kind": "agreement", "conditions": [:], "text": text,
                    "action": "assertion", "deadline": NSNull(), "decisionDate": NSNull(), "evidence": [["source":label,"quote":String(text.prefix(1000))]], "links": []]
            }
            base.spy.reply = try base.response(insufficient ? [] : facts, insufficient: insufficient)
            try await onCall?(base.spy.calls)
        }
    }
    func cleanup() async { await worker.stop(); base.cleanup() }
    func meeting(_ id: String, count: Int, owners: Set<UUID>) async throws {
        let folder = base.root.appendingPathComponent("meetings/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let segments = (0..<count).map { ["start": Double($0 * 20), "end": Double($0 * 20 + 10), "text": "Релиз \(id)_MARKER_\($0)"] as [String:Any] }
        try JSONSerialization.data(withJSONObject: ["meetingId":id,"segments":segments]).write(to: folder.appendingPathComponent("transcript.json"), options:.atomic)
        _ = try await MeetingEmbeddingSnapshotReader(root: base.root.appendingPathComponent("meetings")).synchronize(meetingID:id,store:base.store)
        try await base.store.assignMeeting(id,to:owners); try await base.finishIndex()
    }
    func replacementWorker() -> ProjectMemoryQueueWorker {
        .init(store: ProjectStore(url: base.root.appendingPathComponent("knowledge.sqlite")), meetingsRoot: base.root.appendingPathComponent("meetings"), documentsRoot: base.root.appendingPathComponent("copies"), client: base.spy, model:"fake-only")
    }
    func job(_ id: String) async throws -> MemoryQueueJob {
        try #require(try await base.store.memoryQueueSnapshot().jobs.first { $0.source.externalID == id })
    }
    func until(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while try await !condition() {
            if ContinuousClock.now > deadline { Issue.record("Timed out waiting for synthetic worker state"); throw MemoryQueueError.busy }
            try await Task.sleep(for:.milliseconds(5))
        }
    }
}

private actor QueueDeadlineClock {
    private var calls = 0
    let entered: IndexGate
    init(entered: IndexGate) { self.entered = entered }
    func sleep(_ duration: Duration) async throws {
        calls += 1
        if calls == 1 { await entered.wait(); try Task.checkCancellation(); try await Task.sleep(for:.milliseconds(30)) }
        else { try await Task.sleep(for:duration) }
    }
}

@MainActor @Suite struct ProjectMemoryQueueTests {
    @Test func longSourceCoversEveryChunkWithDurableBatchesAndNoSelfRegeneration() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        try await f.meeting("long",count:25,owners:[p])
        await f.worker.start(); await f.worker.waitUntilIdle()
        let job = try await f.job("long")
        #expect(job.state == .completed && job.completeCoverage && job.completedChunks == 25 && job.totalChunks == 25)
        #expect(f.base.spy.calls == 3)
        let events = try await f.base.history.history(projectID:p).entries
        #expect(events.count == 25 && Set(events.flatMap { $0.event.evidenceChunkIDs }).count == 25)
        #expect(events.allSatisfy { $0.event.sources.allSatisfy { $0.key.externalID == "long" } })
        for _ in 0..<3 { await f.worker.changed(); await f.worker.waitUntilIdle() }
        #expect(f.base.spy.calls == 3)
        await f.worker.stop()
        let restarted = f.replacementWorker(); await restarted.start(); await restarted.waitUntilIdle()
        #expect(f.base.spy.calls == 3)
        let db = try ProjectDatabase(url:f.base.root.appendingPathComponent("knowledge.sqlite"))
        #expect(try db.rows("SELECT start,count FROM memory_queue_batches ORDER BY start") == [["0","12"],["12","12"],["24","1"]])
        await restarted.stop(); await f.cleanup()
    }

    @Test func sequentialWorkerUpdatesKeepConflictingDeadlinesAndCompletionAsClaim() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        try await f.base.meeting("a",text:"Релиз 2026-11-26",owners:[p])
        f.onCall = { _ in
            if f.base.spy.payload.contains("2026-12-05") {
                var done = f.base.fact("сделал проверку",kind:"completionClaim"); done["subject"] = "check:load"
                f.base.spy.reply = try f.base.response([f.base.fact("2026-12-05"),done])
            } else { f.base.spy.reply = try f.base.response([f.base.fact()]) }
        }
        await f.worker.start(); await f.worker.waitUntilIdle()
        let first = try #require(try await f.base.history.history(projectID:p).entries.first?.event)
        try await f.base.meeting("b",text:"Релиз 2026-12-05. Я сделал проверку.",owners:[p])
        await f.worker.changed(); await f.worker.waitUntilIdle()
        let history = try await f.base.history.history(projectID:p)
        #expect(history.entries.count == 3 && f.base.spy.calls == 2)
        #expect(history.entries.contains { $0.event.statement.kind == .completionClaim })
        #expect(try await f.base.history.heads(projectID:p).heads.contains {
            $0.entry.event.statement.kind == .deadline && !$0.usableAsCurrent && $0.conflictingEventIDs == [first.id]
        })
        let next = try #require(history.entries.first { $0.event.statement.deadline?.earliest == f.base.day("2026-12-05") }?.event.id)
        let proof = try await f.base.history.provenance(eventID:next)
        #expect(proof.events.contains { $0.id == first.id } && Set(proof.sources.map { $0.key.externalID }) == ["a","b"])
        #expect(proof.sources.allSatisfy { $0.chunk.location.startSeconds == 42.5 })
        #expect(try await f.job("a").completeCoverage)
        #expect(try await f.job("b").completeCoverage)
        await f.worker.changed(); await f.worker.waitUntilIdle(); await f.worker.stop()
        let restart = f.replacementWorker(); await restart.start(); await restart.waitUntilIdle()
        #expect(f.base.spy.calls == 2)
        await restart.stop(); await f.cleanup()
    }

    @Test func workerRechecksAllOwnersBeforeEveryTransportAttempt() async throws {
        let f = try QueueFixture(); let p = try await f.base.project(), q = try await f.base.project("Общий владелец")
        let doc = try await f.base.document(owners:[p,q]); f.base.spy.attempts = 2
        f.onCall = { _ in try await f.base.store.setCloudPolicy(.localOnly,for:q) }
        await f.worker.start(); await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 1)
        let jobs = try await f.base.store.memoryQueueSnapshot().jobs.filter { $0.source.externalID == doc.uuidString }
        #expect(jobs.count == 2 && jobs.allSatisfy { $0.state == .denied && $0.completedChunks == 0 && !$0.completeCoverage })
        #expect(try await f.base.history.history(projectID:p).entries.isEmpty)
        #expect(try await f.base.history.history(projectID:q).entries.isEmpty)
        let db = try ProjectDatabase(url:f.base.root.appendingPathComponent("knowledge.sqlite"))
        #expect(try db.rows("SELECT COUNT(*) FROM memory_queue_batches") == [["0"]])
        await f.cleanup()
    }

    @Test func insufficientCoveragePersistsAndRestartDoesNotAskModelAgain() async throws {
        let f = try QueueFixture(); let p = try await f.base.project(); f.insufficient = true
        try await f.meeting("long",count:25,owners:[p]); await f.worker.start(); await f.worker.waitUntilIdle()
        let job = try await f.job("long")
        #expect(job.state == .insufficient && job.completeCoverage && job.completedChunks == 25 && f.base.spy.calls == 3)
        #expect(try await f.base.history.history(projectID:p).entries.isEmpty)
        await f.worker.stop(); f.insufficient = false
        let restart = f.replacementWorker(); await restart.start(); await restart.waitUntilIdle()
        #expect(f.base.spy.calls == 3)
        await restart.stop(); await f.cleanup()
    }

    @Test func restartMidSourceKeepsCompletedCursorAndFencesNoncooperativeOldRun() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        try await f.meeting("long",count:25,owners:[p])
        let entered = IndexGate(), release = IndexGate()
        f.onCall = { call in if call == 2 { await entered.signal(); await release.wait() } }
        await f.worker.start(); await entered.wait()
        #expect(try await f.job("long").completedChunks == 12)
        await f.worker.stop()
        let restarted = f.replacementWorker(); await restarted.start(); await restarted.waitUntilIdle()
        await release.signal(); await f.worker.waitUntilIdle()
        let job = try await f.job("long")
        #expect(job.completeCoverage && job.completedChunks == 25 && f.base.spy.calls == 4)
        let events = try await f.base.history.history(projectID:p).entries
        #expect(events.count == 25 && Set(events.flatMap { $0.event.evidenceChunkIDs }).count == 25)
        #expect(f.payloads.filter { $0.contains("long_MARKER_0\"") }.count == 1)
        await restarted.stop(); await f.cleanup()
    }

    @Test func roundRobinDoesNotStarveShortSourceBehindManyBatches() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        try await f.meeting("a",count:25,owners:[p]); try await f.meeting("b",count:1,owners:[p])
        await f.worker.start(); await f.worker.waitUntilIdle()
        #expect(f.payloads.count == 4 && f.payloads[0].contains("a_MARKER_0") && f.payloads[1].contains("b_MARKER_0"))
        #expect(try await f.job("a").completeCoverage)
        #expect(try await f.job("b").completeCoverage)
        await f.cleanup()
    }

    @Test func oneTimeConsentIsFreshForEachBatchAndNotRestoredAsBackgroundPermission() async throws {
        let f = try QueueFixture(); let p = try await f.base.project(policy:.askEveryTime)
        try await f.meeting("long",count:13,owners:[p]); await f.worker.start(); await f.worker.waitUntilIdle()
        let job = try await f.job("long")
        #expect(job.state == .needsConsent && f.base.spy.calls == 0)
        let request = try await f.worker.preparePreview(job.sequence)
        #expect(request.fragments.count == 12 && f.base.spy.calls == 0)
        await f.worker.waitUntilIdle()
        try await f.worker.approvePreview(request.id); await f.worker.waitUntilIdle()
        let partial = try await f.job("long")
        #expect(partial.completedChunks == 12 && partial.state == .needsConsent && !partial.completeCoverage && f.base.spy.calls == 1)
        await f.worker.stop()
        let restart = f.replacementWorker(); await restart.start(); await restart.waitUntilIdle()
        #expect(f.base.spy.calls == 1)
        await #expect(throws:MemoryUpdateError.invalidConsent) { try await restart.approvePreview(request.id) }
        let next = try await restart.preparePreview(job.sequence)
        #expect(next.id != request.id && next.fragments.count == 1)
        await restart.waitUntilIdle(); try await restart.approvePreview(next.id); await restart.waitUntilIdle()
        #expect(try await f.job("long").completeCoverage)
        #expect(f.base.spy.calls == 2)
        await restart.stop(); await f.cleanup()
    }

    @Test func rawAndDerivedPrivateOwnersDenyWorkerWithoutReadingKeysOrCallingTransport() async throws {
        let f = try QueueFixture(); let p = try await f.base.project(), q = try await f.base.project("Приватный",policy:.localOnly)
        let secret = try await f.base.document("Релиз PRIVATE 2026-11-26",owners:[p,q]), hs = try await f.base.hit(secret.uuidString,project:p)
        _ = try await f.base.seed(project:p,hit:hs,text:"Производный PRIVATE 2026-11-26")
        let visible = try await f.base.document("Релиз VISIBLE 2026-11-26",owners:[p])
        await f.worker.start(); await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 0)
        let jobs = try await f.base.store.memoryQueueSnapshot().jobs
        #expect(jobs.allSatisfy { $0.state == .denied && !$0.completeCoverage })
        #expect(jobs.contains { $0.source.externalID == visible.uuidString })
        await f.cleanup()
    }

    @Test func cancelRetryDrainsNoncooperativeAdapterBeforeStartingNextAttempt() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        try await f.meeting("one",count:1,owners:[p])
        let entered = IndexGate(), release = IndexGate()
        f.onCall = { i in if i == 1 { await entered.signal(); await release.wait() } }
        await f.worker.start(); await entered.wait(); let job = try await f.job("one")
        await f.worker.cancel(job.sequence); await f.worker.retry(job.sequence)
        #expect(f.base.spy.calls == 1)
        await release.signal(); await f.worker.waitUntilIdle()
        let afterRetry = try await f.base.history.history(projectID:p)
        #expect(f.base.spy.calls == 2 && afterRetry.entries.count == 1)
        #expect(try await f.job("one").completeCoverage)
        await f.cleanup()
    }

    @Test func injectedDeadlineFencesLateReplyAndDoesNotStartOverlappingAttempt() async throws {
        let entered = IndexGate(), release = IndexGate(), clock = QueueDeadlineClock(entered: entered)
        let f = try QueueFixture(timeout:.seconds(30),sleep:{ try await clock.sleep($0) })
        let p = try await f.base.project(); try await f.meeting("one",count:1,owners:[p])
        f.onCall = { i in if i == 1 { await entered.signal(); await release.wait() } }
        await f.worker.start(); await entered.wait()
        try await f.until { try await f.job("one").state == .failed }
        let job = try await f.job("one"); await f.worker.retry(job.sequence)
        #expect(f.base.spy.calls == 1)
        await release.signal(); await f.worker.waitUntilIdle()
        #expect(try await f.job("one").completeCoverage)
        #expect(try await f.base.history.history(projectID:p).entries.count == 1)
        await f.cleanup()
    }

    @Test func concreteMetadataBridgeReceivesReadyEventWithoutLaunchingApplication() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        let center = NotificationCenter()
        let bridge = KnowledgeMemoryQueue(worker:f.worker,center:center,model:"fake-only")
        bridge.start(); try await f.until { f.worker.snapshot().revision > 0 }
        try await f.meeting("late",count:1,owners:[p])
        KnowledgeIndexEvents.post(.meeting("late"),center:center)
        try await f.until { try await f.base.store.memoryQueueSnapshot().jobs.first { $0.source.externalID == "late" }?.completeCoverage == true }
        #expect(f.base.spy.calls == 1)
        bridge.stop(); await f.cleanup()
    }

    @Test func queueFenceRejectsSkippedChunksEvenIfCallerClaimsWholeBatch() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        try await f.meeting("long",count:13,owners:[p]); await f.worker.changed()
        let run = try await f.base.store.startMemoryQueueRun()
        let lease = try #require(try await f.base.store.claimMemoryQueue(run:run,after:nil))
        let h = try await f.base.hit("long",project:p)
        await #expect(throws:MemoryUpdateError.invalidContext) {
            try await f.base.service.prepare(projectID:p,hits:[h],queue:lease)
        }
        #expect(f.base.spy.calls == 0)
        await f.cleanup()
    }

    @Test func preexistingExactJournalBatchRecordsUnchangedDispositionWithoutSendingAgain() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        let doc = try await f.base.document(owners:[p]), h = try await f.base.hit(doc.uuidString,project:p)
        let request = try await f.base.service.prepare(projectID:p,hits:[h])
        _ = try await f.base.service.update(request)
        #expect(f.base.spy.calls == 1)
        await f.worker.start(); await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 1)
        let db = try ProjectDatabase(url:f.base.root.appendingPathComponent("knowledge.sqlite"))
        #expect(try db.rows("SELECT outcome FROM memory_queue_batches") == [["unchanged"]])
        #expect(try await f.job(doc.uuidString).completeCoverage)
        await f.cleanup()
    }

    @Test func adaptiveJSONBudgetProcessesLongQuotedSourceWithoutSilentSkip() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        let folder = f.base.root.appendingPathComponent("meetings/quoted")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let segments = (0..<25).map { ["start":Double($0 * 20),"end":Double($0 * 20 + 10),"text":"Релиз MARKER_\($0) " + String(repeating:"\"",count:1000)] as [String:Any] }
        try JSONSerialization.data(withJSONObject:["meetingId":"quoted","segments":segments]).write(to:folder.appendingPathComponent("transcript.json"))
        _ = try await MeetingEmbeddingSnapshotReader(root:f.base.root.appendingPathComponent("meetings")).synchronize(meetingID:"quoted",store:f.base.store)
        try await f.base.store.assignMeeting("quoted",to:[p]); try await f.base.finishIndex()
        await f.worker.start(); await f.worker.waitUntilIdle()
        #expect(try await f.job("quoted").completeCoverage)
        #expect(f.payloads.allSatisfy { $0.count <= 24_000 && $0.utf8.count <= 64_000 })
        let events = try await f.base.history.history(projectID:p).entries
        #expect(events.count == 25 && Set(events.flatMap { $0.event.evidenceChunkIDs }).count == 25)
        await f.cleanup()
    }

    @Test(arguments:["source","parent"])
    func changeBetweenBatchesStartsNewCycleAndNeverReportsOldPartialAsComplete(_ kind:String) async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        var parentDoc: UUID?
        if kind == "parent" {
            parentDoc = try await f.base.document("Релиз PARENT 2026-11-26",owners:[p])
            let h = try await f.base.hit(try #require(parentDoc).uuidString,project:p)
            _ = try await f.base.seed(project:p,hit:h)
        }
        try await f.meeting("long",count:13,owners:[p])
        await f.worker.changed()
        if let parentDoc {
            let parentJob = try await f.job(parentDoc.uuidString)
            try await f.base.store.cancelMemoryQueue(parentJob.sequence)
        }
        let initialInput = try await f.job("long").input
        f.onCall = { call in
            if call == 2 {
                if let parentDoc { _ = try await f.base.document("Релиз NEW_PARENT 2026-12-05",owners:[p],target:parentDoc) }
                else { try await f.meeting("long",count:14,owners:[p]) }
            }
        }
        await f.worker.start(); await f.worker.waitUntilIdle()
        let job = try await f.job("long")
        #expect(job.completeCoverage && job.completedChunks == (kind == "source" ? 14 : 13))
        #expect((job.input == initialInput) == (kind == "parent"))
        let db = try ProjectDatabase(url:f.base.root.appendingPathComponent("knowledge.sqlite"))
        let cycles = try db.rows("SELECT cycle,SUM(count) FROM memory_queue_batches WHERE source_key='meeting:long' GROUP BY cycle ORDER BY SUM(count)")
        #expect(cycles.count == 2 && cycles.map { $0[1] } == ["12",kind == "source" ? "14" : "13"])
        let events = try await f.base.history.history(projectID:p).entries
        #expect(events.filter { $0.evidenceState == .stale }.count >= 12)
        #expect(f.base.spy.calls == 4)
        await f.worker.changed(); await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 4)
        await f.cleanup()
    }

    @Test(arguments:["cancel","newRun","modelABA","ownerABA","policyABA","revision","sourceABA","parentManual"])
    func durableQueueFenceRejectsLateTransportWithoutRelyingOnTaskCancellation(_ kind:String) async throws {
        let f = try QueueFixture(); let p = try await f.base.project(), q = try await f.base.project("Другой")
        let doc = try await f.base.document(owners:[p]), h = try await f.base.hit(doc.uuidString,project:p)
        var parent: UUID?
        if kind == "parentManual" {
            let other = try await f.base.document("Релиз PARENT 2026-11-26",owners:[p]), hp = try await f.base.hit(other.uuidString,project:p)
            parent = try await f.base.seed(project:p,hit:hp)
        }
        await f.worker.changed()
        let run = try await f.base.store.startMemoryQueueRun(), job = try await f.job(doc.uuidString)
        let lease = try #require(try await f.base.store.claimMemoryQueue(run:run,after:nil,explicit:job.sequence))
        let request = try await f.base.service.prepare(projectID:p,hits:[h],parentEventIDs:parent.map { [$0] } ?? [],queue:lease)
        f.base.spy.beforeAttempt = { _ in
            switch kind {
            case "cancel": try await f.base.store.cancelMemoryQueue(job.sequence)
            case "newRun": _ = try await f.base.store.startMemoryQueueRun()
            case "modelABA":
                try await f.base.store.activateEmbeddingModel(.init(id:"other",dimensions:2)); try await f.base.finishIndex()
            case "ownerABA":
                let db = try ProjectDatabase(url:f.base.root.appendingPathComponent("knowledge.sqlite"))
                try db.execute("INSERT INTO document_projects VALUES (?,?)",bindings:[doc.uuidString,q.uuidString])
                try db.execute("DELETE FROM document_projects WHERE document_id=? AND project_id=?",bindings:[doc.uuidString,q.uuidString])
            case "policyABA":
                try await f.base.store.setCloudPolicy(.localOnly,for:p); try await f.base.store.setCloudPolicy(.allowSelectedContext,for:p)
            case "revision": _ = try await f.base.document("Релиз 2026-12-05",owners:[p],target:doc)
            case "sourceABA": try await f.base.store.removeEmbeddingSource(h.source.key); try await f.base.store.synchronizeEmbeddingDocuments(); try await f.base.finishIndex()
            default:
                let original = try #require(parent), event = try await f.base.store.memoryEvent(original)
                let manual = try await f.base.history.beginCorrection(eventID:original,intentID:UUID())
                _ = try await f.base.history.publish([.init(statement:event.statement,evidenceChunkIDs:Set(event.evidenceChunkIDs))],lease:manual)
            }
        }
        do { _ = try await f.base.service.update(request); Issue.record("Stale queue permit reached transport") } catch {}
        #expect(f.base.spy.calls == 0)
        let db = try ProjectDatabase(url:f.base.root.appendingPathComponent("knowledge.sqlite"))
        #expect(try db.rows("SELECT COUNT(*) FROM memory_queue_batches") == [["0"]])
        #expect(try await f.job(doc.uuidString).completedChunks == 0)
        await f.cleanup()
    }

    @Test func capAndInvalidReplyLeaveCursorUnchangedAndDoNotRetryOnDuplicateEvents() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        let doc = try await f.base.document(owners:[p]), h = try await f.base.hit(doc.uuidString,project:p)
        let statement = MemoryStatement(subject:"release:sever",kind:.deadline,conditions:["environment":"production"],text:"Релиз 2026-11-26",deadline:.init(earliest:f.base.day("2026-11-26"),latest:f.base.day("2026-11-26")))
        for i in 0..<8 {
            let lease = try await f.base.history.begin(projectID:p,producerKey:"cap-\(i)",hits:[h])
            _ = try await f.base.history.publish(Array(repeating:.init(statement:statement,evidenceChunkIDs:[h.id]),count:32),lease:lease)
        }
        f.onCall = { _ in f.base.spy.reply = try f.base.response([f.base.fact()]) }
        await f.worker.start(); await f.worker.waitUntilIdle()
        let job = try await f.job(doc.uuidString)
        #expect(job.state == .limited && job.completedChunks == 0 && job.message.contains("256"))
        await f.worker.changed(); await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 1)
        let db = try ProjectDatabase(url:f.base.root.appendingPathComponent("knowledge.sqlite"))
        #expect(try db.rows("SELECT COUNT(*) FROM memory_events") == [["256"]])
        #expect(try db.rows("SELECT COUNT(*) FROM memory_queue_batches") == [["0"]])
        await f.cleanup()
    }

    @Test func metadataAndIndexSubscriptionsCoalesceAndSettingsCanStopThenResumeSameWorker() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        let settings = CurrentValueSubject<(Bool,String),Never>((false,"fake-only"))
        let pair = AsyncStream<LocalIndexingSnapshot>.makeStream(bufferingPolicy:.bufferingNewest(1))
        let bridge = KnowledgeMemoryQueue(worker:f.worker,enabled:false,model:"fake-only",indexUpdates:{pair.stream},configuration:settings.eraseToAnyPublisher())
        bridge.start(); try await f.meeting("one",count:1,owners:[p]); pair.continuation.yield(.init())
        try await Task.sleep(for:.milliseconds(150))
        #expect(f.base.spy.calls == 0)
        let entered = IndexGate(), release = IndexGate()
        f.onCall = { i in if i == 1 { await entered.signal(); await release.wait() } }
        settings.send((true,"fake-only")); await entered.wait()
        settings.send((false,"fake-only"))
        try await f.until { try await f.job("one").state != .running }
        settings.send((true,"fake-only")); await release.signal()
        try await f.until { try await f.job("one").completeCoverage }
        #expect(f.base.spy.calls == 2)
        pair.continuation.finish(); bridge.stop(); await f.cleanup()
    }


    @Test func latestDisabledConfigurationWinsQueuedEnableAndBridgeStop() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        try await f.meeting("ready",count:1,owners:[p])
        let configuration = PassthroughSubject<(Bool,String),Never>()
        let bridge = KnowledgeMemoryQueue(worker:f.worker,center:NotificationCenter(),enabled:false,model:"fake-only",configuration:configuration.eraseToAnyPublisher())
        bridge.start()
        for i in 0..<20 { configuration.send((true,"model-\(i)")); configuration.send((false,"model-\(i)")) }
        for _ in 0..<10 { await Task.yield() }
        await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 0)
        configuration.send((true,"final-model")); bridge.stop()
        for _ in 0..<10 { await Task.yield() }
        await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 0)
        await f.cleanup()
    }

    @Test func manualHeadSurvivesQueuedExtractionAndOnlyAffectedJobStartsNewCycle() async throws {
        let f = try QueueFixture(); let p = try await f.base.project(), q = try await f.base.project("Другой")
        let doc = try await f.base.document(owners:[p]), h = try await f.base.hit(doc.uuidString,project:p)
        let other = try await f.base.document("Релиз OTHER 2026-12-05",owners:[q])
        let statement = MemoryStatement(subject:"fact:" + MemoryEncoding.hash(h.chunk.text),kind:.agreement,conditions:[:],text:"Исходная модельная формулировка")
        let initial = try await f.base.history.begin(projectID:p,producerKey:"manual-seed",hits:[h])
        let event = try #require(try await f.base.history.publish([.init(statement:statement,evidenceChunkIDs:[h.id])],lease:initial).eventIDs.first)
        let manualLease = try await f.base.history.beginCorrection(eventID:event,intentID:UUID())
        let manual = try #require(try await f.base.history.publish([.init(statement:statement,evidenceChunkIDs:[h.id])],lease:manualLease).eventIDs.first)
        await f.worker.start(); await f.worker.waitUntilIdle()
        #expect(try await f.base.history.heads(projectID:p).heads.first?.entry.event.id == manual)
        let before = try await f.job(doc.uuidString), otherBefore = try await f.job(other.uuidString)
        let calls = f.base.spy.calls
        let changed = try await f.base.history.beginCorrection(eventID:manual,intentID:UUID())
        let latest = try #require(try await f.base.history.publish([.init(statement:statement,evidenceChunkIDs:[h.id])],lease:changed).eventIDs.first)
        await f.worker.changed(); await f.worker.waitUntilIdle()
        let after = try await f.job(doc.uuidString), otherAfter = try await f.job(other.uuidString)
        #expect(after.cycle != before.cycle && after.completeCoverage)
        #expect(otherAfter.cycle == otherBefore.cycle && otherAfter.completeCoverage)
        #expect(f.base.spy.calls == calls)
        #expect(try await f.base.history.heads(projectID:p).heads.first?.entry.event.id == latest)
        await f.cleanup()
    }

    @Test func discoveryHasBoundedHotWindowAndDeferredJobIsClaimableWithoutDroppingMetadata() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        let reader = MeetingEmbeddingSnapshotReader(root:f.base.root.appendingPathComponent("meetings"))
        for i in 0..<130 {
            let id = String(format:"source-%03d",i), folder = f.base.root.appendingPathComponent("meetings/" + id)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:["meetingId":id,"segments":[["start":0,"end":1,"text":"Релиз \(i)"]]]).write(to:folder.appendingPathComponent("transcript.json"))
            _ = try await reader.synchronize(meetingID:id,store:f.base.store)
            try await f.base.store.assignMeeting(id,to:[p])
        }
        try await f.base.finishIndex(); await f.worker.changed()
        let snapshot = try await f.base.store.memoryQueueSnapshot()
        #expect(snapshot.jobs.count == 130 && snapshot.backpressured)
        #expect(snapshot.jobs.filter { $0.state == .queued }.count == 128)
        #expect(snapshot.jobs.filter { $0.state == .backpressured }.count == 2)
        let deferred = try #require(snapshot.jobs.first { $0.state == .backpressured })
        let run = try await f.base.store.startMemoryQueueRun()
        let lease = try #require(try await f.base.store.claimMemoryQueue(run:run,after:deferred.sequence - 1))
        #expect(lease.job.sequence == deferred.sequence && f.base.spy.calls == 0)
        try await f.base.store.cancelMemoryQueue(lease.job.sequence)
        await f.cleanup()
    }

    @Test func invalidBatchRollsBackJournalAndCursorWhileErrorWaitsForExplicitRetry() async throws {
        let f = try QueueFixture(); let p = try await f.base.project()
        let doc = try await f.base.document(owners:[p])
        f.onCall = { _ in
            var invalid = f.base.fact(); invalid["subject"] = ""
            f.base.spy.reply = try f.base.response([f.base.fact(),invalid])
        }
        await f.worker.start(); await f.worker.waitUntilIdle()
        let job = try await f.job(doc.uuidString)
        #expect(job.state == .failed && job.completedChunks == 0)
        #expect(try await f.base.history.history(projectID:p).entries.isEmpty)
        let db = try ProjectDatabase(url:f.base.root.appendingPathComponent("knowledge.sqlite"))
        #expect(try db.rows("SELECT COUNT(*) FROM memory_queue_batches") == [["0"]])
        await f.worker.changed(); await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 1)
        f.onCall = nil; await f.worker.retry(job.sequence); await f.worker.waitUntilIdle()
        #expect(try await f.job(doc.uuidString).completeCoverage)
        #expect(f.base.spy.calls == 2)
        await f.cleanup()
    }

}
