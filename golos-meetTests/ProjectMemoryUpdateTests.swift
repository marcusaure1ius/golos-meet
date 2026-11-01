import Foundation
import Testing
@testable import golos_meet

@MainActor private final class MemoryTransportSpy: ChatCompleter {
    var calls = 0
    var attempts = 1
    var payload = ""
    var system = ""
    var reply = ""
    var failure: Error?
    var beforeAttempt: ((Int) async throws -> Void)?
    var afterAttempt: ((Int) async throws -> Void)?
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        try await send(messages, check: {})
    }
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?, beforeSending: @escaping @Sendable () async throws -> Void) async throws -> String {
        try await send(messages, check: beforeSending)
    }
    private func send(_ messages: [ChatMessage], check: @Sendable () async throws -> Void) async throws -> String {
        for attempt in 1...attempts {
            try await beforeAttempt?(attempt); try await check()
            calls += 1; payload = messages.last?.content ?? ""; system = messages.first?.content ?? ""
            try await afterAttempt?(attempt)
        }
        if let failure { throw failure }; return reply
    }
}

@MainActor private final class UpdateFixture {
    let root: URL
    let store: ProjectStore
    let history: ProjectMemoryHistoryService
    let importer: DocumentImporter
    let search: KnowledgeSearchService
    let spy = MemoryTransportSpy()
    let service: ProjectMemoryUpdateService
    let embeddingModel = EmbeddingIndexModel(id: "synthetic-update-storage", dimensions: 2)
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-update-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let meetings = root.appendingPathComponent("meetings"), copies = root.appendingPathComponent("copies")
        importer = DocumentImporter(store: store, root: copies)
        search = KnowledgeSearchService(store: store, meetingsRoot: meetings, documentsRoot: copies, queryEmbedding: { _ in throw LocalIndexingError.missingModel })
        history = .init(store: store, meetingsRoot: meetings, documentsRoot: copies)
        service = .init(store: store, meetingsRoot: meetings, documentsRoot: copies, client: spy, model: "fake-only",
            now: { ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")! })
    }
    func cleanup() { service.cancel(); try? FileManager.default.removeItem(at: root) }
    func project(_ name: String = "Север", policy: ProjectCloudPolicy = .allowSelectedContext) async throws -> UUID {
        let p = try await store.createProject(name: name); try await store.setCloudPolicy(policy, for: p.id); return p.id
    }
    @discardableResult func document(_ text: String = "Релиз 2026-11-26", owners: Set<UUID>, target: UUID? = nil, ready: Bool = true) async throws -> UUID {
        let file = root.appendingPathComponent("\(UUID()).txt"); try Data(text.utf8).write(to: file)
        let id = try await importer.importFile(id: UUID(), url: file, projectIDs: owners, targetID: target) { _ in }.documentID
        if ready { try await finishIndex() }; return id
    }
    func meeting(_ id: String, text: String, owners: Set<UUID>) async throws {
        let folder = root.appendingPathComponent("meetings/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["meetingId": id, "segments": [["start": 42.5, "end": 55, "text": text]]]).write(to: folder.appendingPathComponent("transcript.json"))
        _ = try await MeetingEmbeddingSnapshotReader(root: root.appendingPathComponent("meetings")).synchronize(meetingID: id, store: store)
        try await store.assignMeeting(id, to: owners); try await finishIndex()
    }
    func finishIndex() async throws {
        if try await store.knowledgeSearchModel().model != embeddingModel { try await store.activateEmbeddingModel(embeddingModel) }
        while let lease = try await store.claimEmbeddingJob() {
            let vectors = try lease.snapshot.chunks.map { chunk in IndexedChunkVectors(chunkID: chunk.id, bodyTokenCount: 20,
                windows: [.init(tokenStart: 0, tokenCount: 20, vector: try KnowledgeVector(modelID: embeddingModel.id, values: [1, 0]))]) }
            try #require(try await store.publishEmbeddingVectors(vectors, lease: lease))
        }
    }
    func hit(_ id: String, project: UUID) async throws -> KnowledgeSearchHit {
        try #require(try await search.search("релиз", scope: .project(project)).hits.first { $0.source.key.externalID == id })
    }
    func fact(_ quote: String = "2026-11-26", source: String = "S1", kind: String = "deadline") -> [String: Any] {
        ["subject": "release:sever", "kind": kind, "conditions": ["environment": "production"], "text": "Релиз \(quote)",
         "action": "assertion", "decisionDate": NSNull(), "deadline": kind == "deadline" ? ["earliest": quote, "latest": quote] as Any : NSNull(),
         "evidence": [["source": source, "quote": quote]], "links": []]
    }
    func response(_ facts: [[String: Any]], insufficient: Bool = false) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["facts": facts, "insufficientEvidence": insufficient]), as: UTF8.self)
    }
    func seed(project: UUID, hit: KnowledgeSearchHit, text: String = "Релиз 2026-11-26") async throws -> UUID {
        let lease = try await history.begin(projectID: project, producerKey: "synthetic-seed", hits: [hit])
        let statement = MemoryStatement(subject: "release:sever", kind: .deadline, conditions: ["environment": "production"], text: text,
            deadline: .init(earliest: day("2026-11-26"), latest: day("2026-11-26")))
        return try #require(try await history.publish([.init(statement: statement, evidenceChunkIDs: [hit.id])], lease: lease).eventIDs.first)
    }
    func day(_ value: String) -> Date { ISO8601DateFormatter().date(from: value + "T00:00:00Z")! }
}

@MainActor @Suite struct ProjectMemoryUpdateTests {
    @Test func sequentialReadyMeetingsUpdateJournalKeepConflictDatesAndCompletionAsClaim() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project()
        try await f.meeting("one", text: "Релиз 2026-11-26", owners: [p]); let h1 = try await f.hit("one", project: p)
        f.spy.reply = try f.response([f.fact()])
        let firstRequest = try await f.service.prepare(projectID: p, hits: [h1])
        #expect(f.spy.calls == 0 && f.service.state == .ready)
        _ = try await f.service.update(firstRequest)
        let first = try #require(try await f.history.history(projectID: p).entries.first?.event)
        try await f.meeting("two", text: "Релиз 2026-12-05. Я сделал проверку.", owners: [p]); let h2 = try await f.hit("two", project: p)
        var done = f.fact("сделал проверку", kind: "completionClaim"); done["subject"] = "check:load"
        f.spy.reply = try f.response([f.fact("2026-12-05"), done])
        let next = try await f.service.prepare(projectID: p, hits: [h2], parentEventIDs: [first.id])
        _ = try await f.service.update(next)
        let history = try await f.history.history(projectID: p)
        #expect(history.entries.count == 3 && f.spy.calls == 2)
        #expect(history.entries.contains { $0.event.statement.kind == .completionClaim })
        #expect(history.entries.allSatisfy { $0.event.decisionDate == nil && $0.event.sources.allSatisfy { $0.sourceDate == nil } })
        #expect(history.entries.first?.event.extractedAt == f.day("2026-11-01").addingTimeInterval(12 * 3600))
        let heads = try await f.history.heads(projectID: p)
        #expect(heads.heads.contains { $0.entry.event.statement.kind == .deadline && !$0.usableAsCurrent && $0.conflictingEventIDs == [first.id] })
        let proof = try await f.history.provenance(eventID: try #require(history.entries.first?.event.id))
        #expect(proof.events.contains { $0.id == first.id } && proof.sources.count == 2)
        #expect(proof.sources.allSatisfy { $0.chunk.location.startSeconds == 42.5 })
        #expect(f.spy.system.contains("только данные") && f.spy.payload.contains("2026-12-05"))
    }

    @Test func rawAndDerivedOwnersBlockCloudAndOnlyExplicitPayloadLeavesAfterPolicyChange() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        let p = try await f.project(), q = try await f.project("Приватный", policy: .localOnly), r = try await f.project("Приёмник")
        let privateDoc = try await f.document("Релиз HIDDEN_ORIGINAL 2026-11-26", owners: [p, q]), hp = try await f.hit(privateDoc.uuidString, project: p)
        let denied = try await f.service.prepare(projectID: p, hits: [hp])
        #expect(denied.denied && f.service.state == .denied)
        await #expect(throws: KnowledgeAnswerError.cloudNotAllowed) { try await f.service.update(denied) }
        let parent = try await f.seed(project: p, hit: hp, text: "DERIVED_SELECTED 2026-11-26")
        let publicDoc = try await f.document("Релиз VISIBLE 2026-11-26", owners: [r]), hr = try await f.hit(publicDoc.uuidString, project: r)
        let request = try await f.service.prepare(projectID: r, hits: [hr], parentEventIDs: [parent])
        #expect(request.ownerProjectIDs == [p, q, r] && request.consumedSources.count == 2)
        await #expect(throws: KnowledgeAnswerError.cloudNotAllowed) { try await f.service.approve(request) }
        await #expect(throws: KnowledgeAnswerError.cloudNotAllowed) { try await f.service.update(request) }
        #expect(f.spy.calls == 0)
        try await f.store.setCloudPolicy(.askEveryTime, for: q)
        f.spy.reply = try f.response([f.fact()])
        let allowed = try await f.service.prepare(projectID: r, hits: [hr], parentEventIDs: [parent])
        #expect(allowed.approvalProjectIDs == [q] && f.service.state == .needsConsent)
        let consent = try await f.service.approve(allowed)
        _ = try await f.service.update(allowed, consent: consent)
        #expect(f.spy.calls == 1 && f.spy.payload.contains("VISIBLE") && f.spy.payload.contains("DERIVED_SELECTED") && !f.spy.payload.contains("HIDDEN_ORIGINAL"))
        let result = try #require(try await f.history.history(projectID: r).entries.first?.event.id)
        #expect(try await f.history.provenance(eventID: result).ownerProjectIDs == [p, q, r])
    }

    @Test func consentIsRequestSessionScopedConsumedOnFailureAndReplaySurvivesRestartWithoutExtraCloud() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project(policy: .askEveryTime)
        let doc = try await f.document(owners: [p]), h = try await f.hit(doc.uuidString, project: p)
        let request = try await f.service.prepare(projectID: p, hits: [h])
        await #expect(throws: MemoryUpdateError.consentRequired) { try await f.service.update(request) }
        let next = try await f.service.prepare(projectID: p, hits: [h]); let consent = try await f.service.approve(next)
        f.spy.failure = LLMError.noAPIKey
        await #expect(throws: LLMError.noAPIKey) { try await f.service.update(next, consent: consent) }
        f.spy.failure = nil; f.spy.reply = try f.response([f.fact()])
        let retry = try await f.service.prepare(projectID: p, hits: [h])
        await #expect(throws: MemoryUpdateError.invalidConsent) { try await f.service.update(retry, consent: consent) }
        let final = try await f.service.prepare(projectID: p, hits: [h]); let finalConsent = try await f.service.approve(final)
        let result = try await f.service.update(final, consent: finalConsent)
        let reopened = ProjectMemoryUpdateService(store: ProjectStore(url: f.root.appendingPathComponent("knowledge.sqlite")), meetingsRoot: f.root.appendingPathComponent("meetings"), documentsRoot: f.root.appendingPathComponent("copies"), client: f.spy, model: "fake-only")
        let replay = try await reopened.prepare(projectID: p, hits: [h]); let freshConsent = try await reopened.approve(replay)
        let before = f.spy.calls
        let outcome = try await reopened.update(replay, consent: freshConsent)
        if case .published(let publication) = result { #expect(outcome == .published(.unchanged(publication.eventIDs))) }
        else { Issue.record("Expected published result") }
        #expect(f.spy.calls == before && f.service.state == .updated)
        await #expect(throws: MemoryUpdateError.invalidConsent) { try await reopened.update(replay, consent: freshConsent) }
    }

    @Test(arguments: ["policy", "policyABA", "ownersABA", "revision", "fileABA", "recreate", "deleted", "modelABA", "reindex", "manual", "cancel", "projectABA"])
    func changesAtTransportBoundaryPreventSendingOrPublishing(_ change: String) async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project(policy: .askEveryTime), q = try await f.project("Другой")
        let doc = try await f.document(owners: [p]), h = try await f.hit(doc.uuidString, project: p)
        let original = change == "manual" ? try await f.seed(project: p, hit: h) : nil
        f.spy.reply = try f.response([f.fact()])
        let request = try await f.service.prepare(projectID: p, hits: [h]); let consent = try await f.service.approve(request)
        f.spy.beforeAttempt = { _ in
            switch change {
            case "policy", "policyABA":
                try await f.store.setCloudPolicy(.localOnly, for: p)
                if change == "policyABA" { try await f.store.setCloudPolicy(.askEveryTime, for: p) }
            case "ownersABA":
                let db = try ProjectDatabase(url: f.root.appendingPathComponent("knowledge.sqlite"))
                try db.execute("INSERT INTO document_projects VALUES (?,?)", bindings: [doc.uuidString, q.uuidString])
                try db.execute("DELETE FROM document_projects WHERE document_id=? AND project_id=?", bindings: [doc.uuidString, q.uuidString])
            case "revision": _ = try await f.document("Релиз 2026-12-05", owners: [p], target: doc)
            case "fileABA", "recreate":
                let file = try await f.importer.fileURL(for: try #require(h.source.document)), data = try Data(contentsOf: file)
                if change == "recreate" { try FileManager.default.removeItem(at: file) } else { try Data("B".utf8).write(to: file) }
                try data.write(to: file)
            case "deleted": try await f.store.removeEmbeddingSource(h.source.key)
            case "modelABA":
                try await f.store.activateEmbeddingModel(.init(id: "other", dimensions: 2)); try await f.store.activateEmbeddingModel(f.embeddingModel)
            case "reindex": try await f.store.requestEmbeddingReindex(h.source.key)
            case "manual":
                let correction = try await f.history.beginCorrection(eventID: try #require(original), intentID: UUID())
                let event = try await f.store.memoryEvent(try #require(original))
                _ = try await f.history.publish([.init(statement: event.statement, evidenceChunkIDs: [h.id])], lease: correction)
            case "cancel": f.service.cancel()
            default:
                let db = try ProjectDatabase(url: f.root.appendingPathComponent("knowledge.sqlite"))
                try db.execute("DELETE FROM projects WHERE id=?", bindings: [p.uuidString])
                try db.execute("INSERT INTO projects VALUES (?,'Recreated',NULL,'askEveryTime')", bindings: [p.uuidString])
            }
        }
        do { _ = try await f.service.update(request, consent: consent); Issue.record("Changed context sent") } catch {}
        #expect(f.spy.calls == 0)
        #expect(try await f.history.history(projectID: p).entries.count == (change == "manual" ? 2 : 0))
    }

    @Test func everyRetryAndLateReplyRecheckAllOwnersAndForeignParentMemory() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project(), q = try await f.project("Владелец", policy: .askEveryTime)
        let doc = try await f.document(owners: [p, q]), h = try await f.hit(doc.uuidString, project: p)
        let request = try await f.service.prepare(projectID: p, hits: [h]); let consent = try await f.service.approve(request)
        f.spy.attempts = 2; f.spy.reply = try f.response([f.fact()])
        f.spy.afterAttempt = { i in if i == 1 { try await f.store.setCloudPolicy(.localOnly, for: q) } }
        do { _ = try await f.service.update(request, consent: consent); Issue.record("Retry after revocation") } catch {}
        let remaining = try await f.history.history(projectID: p)
        #expect(f.spy.calls == 1 && remaining.entries.isEmpty)
        f.spy.attempts = 1; f.spy.afterAttempt = nil
        try await f.store.setCloudPolicy(.allowSelectedContext, for: q)
        let parent = try await f.seed(project: p, hit: h)
        let r = try await f.project("Получатель"), visible = try await f.document("Релиз получателя 2026-11-26", owners: [r]), hr = try await f.hit(visible.uuidString, project: r)
        let next = try await f.service.prepare(projectID: r, hits: [hr], parentEventIDs: [parent])
        f.spy.afterAttempt = { _ in
            let correction = try await f.history.beginCorrection(eventID: parent, intentID: UUID())
            let event = try await f.store.memoryEvent(parent)
            _ = try await f.history.publish([.init(statement: event.statement, evidenceChunkIDs: [h.id])], lease: correction)
        }
        do { _ = try await f.service.update(next); Issue.record("Published after parent changed") } catch {}
        #expect(try await f.history.history(projectID: r).entries.isEmpty)
    }

    @Test func cancellationOfNoncooperativeTransportCannotAppendAndNewSessionRequiresNewConsent() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project(policy: .askEveryTime)
        let doc = try await f.document(owners: [p]), h = try await f.hit(doc.uuidString, project: p)
        let entered = IndexGate(), release = IndexGate()
        f.spy.reply = try f.response([f.fact()]); f.spy.afterAttempt = { _ in await entered.signal(); await release.wait() }
        let request = try await f.service.prepare(projectID: p, hits: [h]); let consent = try await f.service.approve(request)
        let pending = Task { try await f.service.update(request, consent: consent) }
        await entered.wait(); f.service.cancel(); await release.signal()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(f.service.state == .cancelled)
        #expect(try await f.history.history(projectID: p).entries.isEmpty)
        f.spy.afterAttempt = nil
        let next = try await f.service.prepare(projectID: p, hits: [h])
        await #expect(throws: MemoryUpdateError.invalidConsent) { try await f.service.update(next, consent: consent) }
    }

    @Test(arguments: ["json", "unknownKey", "citation", "quote", "date", "unknownDate", "partial", "empty", "foreignLink", "huge"])
    func invalidStructuredResponseNeverPartiallyPublishes(_ mode: String) async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project()
        let doc = try await f.document(owners: [p]), h = try await f.hit(doc.uuidString, project: p)
        var fact = f.fact(), facts: [[String: Any]] = []
        switch mode {
        case "unknownKey": fact["sourceDate"] = "2026-11-01"
        case "citation": fact["evidence"] = [["source": "S99", "quote": "2026-11-26"]]
        case "quote": fact["evidence"] = [["source": "S1", "quote": "придуманная цитата"]]
        case "date": fact["deadline"] = ["earliest": "2026-12-05", "latest": "2026-12-05"]
        case "unknownDate": fact["decisionDate"] = "2026-11-01"
        case "partial": fact["subject"] = ""; facts = [f.fact()]
        case "foreignLink": fact["links"] = [["target": "M999", "kind": "replaces"]]
        default: break
        }
        facts.append(fact)
        f.spy.reply = mode == "json" ? "broken" : mode == "huge" ? String(repeating: "x", count: 128_001) : try f.response(mode == "empty" ? [] : facts)
        let request = try await f.service.prepare(projectID: p, hits: [h])
        do { _ = try await f.service.update(request); Issue.record("Invalid response accepted") } catch {}
        #expect(try await f.history.history(projectID: p).entries.isEmpty)
        #expect(f.spy.calls == 1 && f.service.state == .failed)
    }

    @Test func insufficientEvidenceNotReadyAndBudgetHaveExplicitStatesAndZeroHistory() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project()
        let doc = try await f.document(owners: [p], ready: false), old = try await f.hit(doc.uuidString, project: p)
        await #expect(throws: MemoryUpdateError.notReady) { try await f.service.prepare(projectID: p, hits: [old]) }
        #expect(f.service.state == .waiting && f.spy.calls == 0)
        try await f.finishIndex(); let h = try await f.hit(doc.uuidString, project: p)
        f.spy.reply = try f.response([], insufficient: true)
        let request = try await f.service.prepare(projectID: p, hits: [h])
        #expect(try await f.service.update(request) == .insufficientEvidence)
        #expect(f.service.state == .insufficientEvidence)
        #expect(try await f.history.history(projectID: p).entries.isEmpty)
        let hugeChunk = KnowledgeChunk(id: h.id, sourceID: h.chunk.sourceID, revision: h.chunk.revision, ordinal: h.chunk.ordinal, text: String(repeating: "я", count: 16_001), location: h.chunk.location)
        let huge = KnowledgeSearchHit(source: h.source, chunk: hugeChunk, model: h.model, scope: h.scope, matchedWords: true, matchedMeaning: false, fileStamp: h.fileStamp)
        await #expect(throws: MemoryUpdateError.contextTooLarge) { try await f.service.prepare(projectID: p, hits: [huge]) }
        #expect(f.spy.calls == 1)
    }

    @Test(arguments: ["model", "parent"])
    func finalJournalTransactionRechecksModelAndForeignMemoryEvenAfterEarlierValidation(_ change: String) async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project(), r = try await f.project("Получатель")
        let doc = try await f.document(owners: [p]), h = try await f.hit(doc.uuidString, project: p)
        let parent = try await f.seed(project: p, hit: h)
        let lease = try await f.history.begin(projectID: r, producerKey: "guard-test", hits: [], parentEventIDs: [parent])
        let validation = try await f.store.memoryUpdateInputs(lease)
        try await f.store.validateMemoryUpdate(lease, guard: validation)
        let event = try await f.store.memoryEvent(parent)
        if change == "model" {
            try await f.store.activateEmbeddingModel(.init(id: "replacement-model", dimensions: 2))
        } else {
            let manual = try await f.history.beginCorrection(eventID: parent, intentID: UUID())
            _ = try await f.history.publish([.init(statement: event.statement, evidenceChunkIDs: [h.id])], lease: manual)
        }
        do {
            _ = try await f.history.publish([.init(statement: event.statement, evidenceChunkIDs: [h.id])], lease: lease, updateGuard: validation)
            Issue.record("Atomic publication ignored update guard")
        } catch { #expect(error is KnowledgeSearchError || error is MemoryUpdateError) }
        #expect(try await f.history.history(projectID: r).entries.isEmpty)
    }

    @Test func explicitReplacementRetractionAndManualPrecedenceKeepHistoryThroughActualExtractor() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project()
        try await f.meeting("one", text: "Релиз 2026-11-26", owners: [p]); let h1 = try await f.hit("one", project: p)
        let original = try await f.seed(project: p, hit: h1)
        try await f.meeting("two", text: "Релиз 2026-12-05 заменяет прежний срок.", owners: [p]); let h2 = try await f.hit("two", project: p)
        var replacement = f.fact("2026-12-05"); replacement["links"] = [["target": "M1", "kind": "replaces"]]
        f.spy.reply = try f.response([replacement])
        let request = try await f.service.prepare(projectID: p, hits: [h2], parentEventIDs: [original])
        _ = try await f.service.update(request)
        let selected = try #require(try await f.history.heads(projectID: p).heads.first)
        #expect(selected.usableAsCurrent && selected.entry.event.id != original)
        let correction = try await f.history.beginCorrection(eventID: selected.entry.event.id, intentID: UUID())
        let manual = try #require(try await f.history.publish([.init(statement: selected.entry.event.statement, evidenceChunkIDs: [h2.id])], lease: correction).eventIDs.first)
        f.spy.reply = try f.response([f.fact("2026-12-05")])
        let automatic = try await f.service.prepare(projectID: p, hits: [h2])
        _ = try await f.service.update(automatic)
        #expect(try await f.history.heads(projectID: p).heads.first?.entry.event.id == manual)
        f.spy.reply = try f.response([replacement])
        let forbidden = try await f.service.prepare(projectID: p, hits: [h2], parentEventIDs: [manual])
        await #expect(throws: MemoryUpdateError.invalidReference) { try await f.service.update(forbidden) }
        // A separate model-origin slot exercises explicit retraction rather
        // than allowing a model to retire the selected manual assertion.
        let q = try await f.project("Отмена")
        try await f.meeting("three", text: "Релиз 2026-11-26 отменён", owners: [q]); let h3 = try await f.hit("three", project: q)
        let target = try await f.seed(project: q, hit: h3)
        var retract = f.fact("отменён"); retract["deadline"] = NSNull(); retract["action"] = "retraction"
        retract["links"] = [["target": "M1", "kind": "retracts"]]
        f.spy.reply = try f.response([retract])
        let withdrawing = try await f.service.prepare(projectID: q, hits: [h3], parentEventIDs: [target])
        _ = try await f.service.update(withdrawing)
        let head = try #require(try await f.history.heads(projectID: q).heads.first)
        #expect(head.entry.event.action == .retraction && !head.usableAsCurrent)
        #expect(try await f.history.history(projectID: q).entries.count == 2)
    }

    @Test func limitedJournalHasExplicitTerminalStateWithoutDeletionOrAutomaticRetry() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project()
        let doc = try await f.document(owners: [p]), h = try await f.hit(doc.uuidString, project: p)
        let statement = MemoryStatement(subject: "release:sever", kind: .deadline, conditions: ["environment": "production"], text: "Релиз 2026-11-26", deadline: .init(earliest: f.day("2026-11-26"), latest: f.day("2026-11-26")))
        for i in 0..<8 {
            let lease = try await f.history.begin(projectID: p, producerKey: "budget-\(i)", hits: [h])
            _ = try await f.history.publish(Array(repeating: .init(statement: statement, evidenceChunkIDs: [h.id]), count: 32), lease: lease)
        }
        f.spy.reply = try f.response([f.fact()])
        let request = try await f.service.prepare(projectID: p, hits: [h])
        await #expect(throws: MemoryUpdateError.candidateLimit) { try await f.service.update(request) }
        #expect(f.service.state == .limited && f.spy.calls == 1)
        let db = try ProjectDatabase(url: f.root.appendingPathComponent("knowledge.sqlite"))
        #expect(try db.rows("SELECT COUNT(*) FROM memory_events") == [["256"]])
    }


    @Test func ancestorManualEditFencesDeepDerivedContextButCurrentCorrectionRetainsItsOwnHistory() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        let p = try await f.project(), r = try await f.project("Промежуточный"), s = try await f.project("Получатель")
        let doc = try await f.document(owners: [p]), h = try await f.hit(doc.uuidString, project: p)
        let original = try await f.seed(project: p, hit: h), event = try await f.store.memoryEvent(original)
        let derivedLease = try await f.history.begin(projectID: r, producerKey: "intermediate", hits: [], parentEventIDs: [original])
        let derived = try #require(try await f.history.publish([.init(statement: event.statement, evidenceChunkIDs: [h.id])], lease: derivedLease).eventIDs.first)
        let visible = try await f.document("Релиз получателя 2026-11-26", owners: [s]), hs = try await f.hit(visible.uuidString, project: s)
        f.spy.reply = try f.response([f.fact()])
        let request = try await f.service.prepare(projectID: s, hits: [hs], parentEventIDs: [derived])
        #expect(Set(request.checkpoint.parentVersions.map(\.projectID)) == [p, r])
        var manual: UUID?
        f.spy.beforeAttempt = { _ in
            let correction = try await f.history.beginCorrection(eventID: original, intentID: UUID())
            manual = try await f.history.publish([.init(statement: event.statement, evidenceChunkIDs: [h.id])], lease: correction).eventIDs.first
        }
        do { _ = try await f.service.update(request); Issue.record("Deep ancestor edit reached transport") } catch {}
        #expect(f.spy.calls == 0)
        f.spy.beforeAttempt = nil
        await #expect(throws: MemoryUpdateError.stale) { try await f.service.prepare(projectID: s, hits: [hs], parentEventIDs: [derived]) }
        let corrected = try await f.service.prepare(projectID: s, hits: [hs], parentEventIDs: [try #require(manual)])
        _ = try await f.service.update(corrected)
        #expect(f.spy.calls == 1)
        let result = try #require(try await f.history.history(projectID: s).entries.first?.event.id)
        let proof = try await f.history.provenance(eventID: result)
        #expect(proof.events.count == 3 && proof.events.contains { $0.id == original })
    }


    @Test(arguments: ["selection", "order", "location", "binding"])
    func selectedInputChangesWithinSameFullClosureProduceNewFactsAndExactReplayAfterRestart(_ mode: String) async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        let p = try await f.project("Родитель"), r = try await f.project("Получатель", policy: .askEveryTime)
        let aText = mode == "location" || mode == "binding" ? "Релиз SAME_QUOTE" : "Релиз RAW_A_SELECTED"
        let bText = mode == "location" || mode == "binding" ? aText : "Релиз RAW_B_PREVIOUSLY_HIDDEN"
        // Distinct meeting IDs retain distinct source/chunk identities even
        // when title/text/location happen to be byte-for-byte equal.
        try await f.meeting("a", text: aText, owners: [p, r])
        try await f.meeting("b", text: bText, owners: [p, r])
        if mode == "location" || mode == "binding" {
            for id in ["a", "b"] {
                try JSONSerialization.data(withJSONObject: ["title": "Одинаковое название"]).write(to: f.root.appendingPathComponent("meetings/\(id)/meta.json"))
            }
        }
        if mode == "location" {
            let file = f.root.appendingPathComponent("meetings/b/transcript.json")
            try JSONSerialization.data(withJSONObject: ["meetingId": "b", "segments": [["start": 80, "end": 90, "text": bText]]]).write(to: file)
            _ = try await MeetingEmbeddingSnapshotReader(root: f.root.appendingPathComponent("meetings")).synchronize(meetingID: "b", store: f.store)
            try await f.finishIndex()
        }
        let pa = try await f.hit("a", project: p), pb = try await f.hit("b", project: p)
        let a = try await f.hit("a", project: r), b = try await f.hit("b", project: r)
        let parentLease = try await f.history.begin(projectID: p, producerKey: "both-consumed", hits: [pa, pb])
        let parent = try #require(try await f.history.publish([.init(statement: .init(subject: "parent-summary", kind: .agreement, conditions: [:], text: "DERIVED_SUMMARY"), evidenceChunkIDs: [pa.id])], lease: parentLease).eventIDs.first)
        let firstHits = mode == "order" ? [a, b] : [a], secondHits = mode == "order" ? [b, a] : [b]
        var factA = f.fact(mode == "selection" || mode == "order" ? "RAW_A_SELECTED" : "SAME_QUOTE", kind: "agreement")
        factA["subject"] = "result-A"; factA["text"] = "Получено из A"
        f.spy.reply = try f.response([factA])
        let first = try await f.service.prepare(projectID: r, hits: firstHits, parentEventIDs: [parent])
        let firstConsent = try await f.service.approve(first)
        let firstOutcome = try await f.service.update(first, consent: firstConsent)
        guard case .published(let firstPublication) = firstOutcome else { Issue.record("Missing A publication"); return }
        #expect(f.spy.calls == 1)
        if mode == "selection" { #expect(!f.spy.payload.contains("RAW_B_PREVIOUSLY_HIDDEN")) }
        func reopened(_ model: String = "fake-only") -> ProjectMemoryUpdateService {
            .init(store: ProjectStore(url: f.root.appendingPathComponent("knowledge.sqlite")), meetingsRoot: f.root.appendingPathComponent("meetings"), documentsRoot: f.root.appendingPathComponent("copies"), client: f.spy, model: model)
        }
        let next = reopened()
        var factB = f.fact(mode == "selection" || mode == "order" ? "RAW_B_PREVIOUSLY_HIDDEN" : "SAME_QUOTE", kind: "agreement")
        factB["subject"] = "result-B"; factB["text"] = "Получено из B"
        f.spy.reply = try f.response([factB])
        let second = try await next.prepare(projectID: r, hits: secondHits, parentEventIDs: [parent])
        #expect(first.consumedSources == second.consumedSources && first.parents == second.parents)
        #expect((first.payload == second.payload) == (mode == "binding"))
        let secondConsent = try await next.approve(second)
        let secondOutcome = try await next.update(second, consent: secondConsent)
        guard case .published(let secondPublication) = secondOutcome else { Issue.record("Missing B publication"); return }
        #expect(f.spy.calls == 2 && Set(firstPublication.eventIDs).isDisjoint(with: secondPublication.eventIDs))
        let aEvent = try await f.store.memoryEvent(try #require(firstPublication.eventIDs.first))
        let bEvent = try await f.store.memoryEvent(try #require(secondPublication.eventIDs.first))
        #expect(aEvent.statement.text == "Получено из A" && bEvent.statement.text == "Получено из B")
        #expect(aEvent.evidenceChunkIDs == [a.id] && bEvent.evidenceChunkIDs == [b.id])
        let proof = try await f.history.provenance(eventID: bEvent.id)
        #expect(proof.sources.count == 2 && proof.ownerProjectIDs == [p, r])
        let db = try ProjectDatabase(url: f.root.appendingPathComponent("knowledge.sqlite"))
        let batches = try db.rows("SELECT producer_key,fingerprint FROM memory_batches WHERE project_id=?", bindings: [r.uuidString])
        #expect(batches.count == 2 && Set(batches.map { $0[0] }).count == 2 && Set(batches.map { $0[1] }).count == 1)
        // Exact input is first-wins, including an attempted different result
        // after a new store/service/session. No extra transport is permitted.
        let replayService = reopened()
        let replay = try await replayService.prepare(projectID: r, hits: secondHits, parentEventIDs: [parent])
        #expect(replay.payload == second.payload && replay.id != second.id)
        let replayConsent = try await replayService.approve(replay)
        f.spy.reply = try f.response([factA])
        #expect(try await replayService.update(replay, consent: replayConsent) == .published(.unchanged(secondPublication.eventIDs)))
        #expect(f.spy.calls == 2)
        // Extraction-model changes distinguish identical payloads without
        // touching index model/readiness or the full provenance fingerprint.
        let otherModel = reopened("other-extraction-model")
        let differentModel = try await otherModel.prepare(projectID: r, hits: secondHits, parentEventIDs: [parent])
        #expect(differentModel.payload == second.payload)
        let modelConsent = try await otherModel.approve(differentModel)
        f.spy.reply = try f.response([factB])
        guard case .published(let modelPublication) = try await otherModel.update(differentModel, consent: modelConsent) else { Issue.record("Missing changed-model publication"); return }
        #expect(f.spy.calls == 3 && Set(modelPublication.eventIDs).isDisjoint(with: secondPublication.eventIDs))
    }

    @Test func ambiguousLegacyServiceBatchIsRetainedButCannotAuthorizeSelectedInputReplay() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }; let p = try await f.project()
        let doc = try await f.document(owners: [p]), h = try await f.hit(doc.uuidString, project: p)
        let oldProducer = MemoryFactExtractor.version + ":" + MemoryEncoding.hash("fake-only")
        let oldLease = try await f.history.begin(projectID: p, producerKey: oldProducer, hits: [h])
        let legacy = try #require(try await f.history.publish([.init(statement: .init(subject: "legacy", kind: .agreement, conditions: [:], text: "Старый результат без exact payload identity"), evidenceChunkIDs: [h.id])], lease: oldLease).eventIDs.first)
        f.spy.reply = try f.response([f.fact()])
        let request = try await f.service.prepare(projectID: p, hits: [h])
        guard case .published(let publication) = try await f.service.update(request) else { Issue.record("Missing v2 publication"); return }
        #expect(f.spy.calls == 1 && !publication.eventIDs.contains(legacy))
        #expect(try await f.store.memoryEvent(legacy).statement.text == "Старый результат без exact payload identity")
        let db = try ProjectDatabase(url: f.root.appendingPathComponent("knowledge.sqlite"))
        let producers = try db.rows("SELECT producer_key FROM memory_batches WHERE project_id=?", bindings: [p.uuidString]).map { $0[0] }
        #expect(producers.contains(oldProducer) && producers.contains { $0.hasPrefix("memory-update-input-v2:") })
        #expect(try db.rows("PRAGMA user_version") == [["7"]])
        let replay = try await f.service.prepare(projectID: p, hits: [h])
        #expect(try await f.service.update(replay) == .published(.unchanged(publication.eventIDs)))
        #expect(f.spy.calls == 1)
    }

}
