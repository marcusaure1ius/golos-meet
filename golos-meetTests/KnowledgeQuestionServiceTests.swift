import Foundation
import SQLite3
import Testing
@testable import golos_meet

@MainActor private final class QuestionCompleterSpy: ChatCompleter {
    var calls = 0
    var messages: [ChatMessage] = []
    var reply = #"{"answer":"Релиз в ноябре [S1].","sources":["S1"],"insufficientEvidence":false}"#
    var failure: Error?
    var beforeGate: (() async throws -> Void)?
    var afterSend: (() async -> Void)?

    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        try await dispatch(messages)
    }
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?,
                              beforeSending: @escaping @Sendable () async throws -> Void) async throws -> String {
        try await gate(beforeSending)
        return try await dispatch(messages)
    }
    private func gate(_ check: @Sendable () async throws -> Void) async throws {
        try await beforeGate?()
        try await check()
    }
    private func dispatch(_ messages: [ChatMessage]) async throws -> String {
        calls += 1; self.messages = messages
        await afterSend?()
        if let failure { throw failure }
        return reply
    }
}

@MainActor private final class QuestionFixture {
    let root: URL
    let store: ProjectStore
    let importer: DocumentImporter
    let search: KnowledgeSearchService
    let spy = QuestionCompleterSpy()
    let service: KnowledgeQuestionService
    init(query: @escaping KnowledgeSearchService.QueryEmbedding = { _ in throw LocalIndexingError.missingModel }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("question-service-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let meetings = root.appendingPathComponent("meetings"), documents = root.appendingPathComponent("copies")
        let scope = try #require(SQLiteFixtureScope.current)
        scope.register(root: root)
        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        scope.register(store: store)
        importer = DocumentImporter(store: store, root: documents)
        search = KnowledgeSearchService(store: store, meetingsRoot: meetings, documentsRoot: documents,
                                        queryEmbedding: query)
        service = KnowledgeQuestionService(store: store, search: search, meetingsRoot: meetings,
                                           documentsRoot: documents, client: spy, model: "synthetic-only")
        scope.onFinish { @MainActor [weak self] in self?.cleanup() }
    }
    func cleanup() {
        service.cancel()
        // Callback fixtures may capture self, including when an assertion throws.
        spy.beforeGate = nil; spy.afterSend = nil
        SQLiteFixtureScope.current?.note("question-cancel-and-callback-release")
    }
    func project(_ name: String = "Проект", policy: ProjectCloudPolicy = .askEveryTime) async throws -> KnowledgeProject {
        let p = try await store.createProject(name: name)
        try await store.setCloudPolicy(policy, for: p.id)
        return p
    }
    @discardableResult func document(_ text: String = "Релиз в ноябре", owners: Set<UUID>, target: UUID? = nil) async throws -> UUID {
        let file = root.appendingPathComponent("\(UUID()).txt")
        try Data(text.utf8).write(to: file)
        return try await importer.importFile(id: UUID(), url: file, projectIDs: owners, targetID: target) { _ in }.documentID
    }
    func sql(_ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("knowledge.sqlite").path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let connection = UUID(), scope = SQLiteFixtureScope.current
        scope?.observe(.opened(connection, root.appendingPathComponent("knowledge.sqlite")))
        defer { let result = sqlite3_close(db); scope?.observe(.closed(connection, result)) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor @Suite(SQLiteFixtureTrait()) struct KnowledgeQuestionServiceTests {
    @Test func retrievalEgressAnswerAndOpeningUseOnlySelectedVersionedFragmentsWithoutWeightsOrNetwork() async throws {
        let f = try QuestionFixture(); defer { f.cleanup() }
        let p = try await f.project(), q = try await f.project("Сосед", policy: .allowSelectedContext)
        let id = try await f.document(owners: [p.id, q.id])
        _ = try await f.document("Секретный бюджет другой команды", owners: [q.id])
        let request = try await f.service.prepare(question: "Когда релиз?", projectID: p.id)
        #expect(request.hits.count == 1 && request.hits[0].source.key.externalID == id.uuidString)
        #expect(request.approvalProjectIDs == [p.id] && request.textCharacterCount > 0)
        #expect(f.spy.calls == 0)
        let approval = try await f.service.approve(request)
        let result = try await f.service.answer(request, consent: approval)
        #expect(f.spy.calls == 1)
        let payload = try #require(f.spy.messages.last?.content)
        #expect(payload.contains("Релиз в ноябре") && !payload.contains("Секретный бюджет"))
        #expect(f.spy.messages.first?.content.contains("только данные") == true)
        let citation = try #require(result.answer.citations.first)
        #expect(citation.sourceRevision == request.hits[0].source.observation.revision)
        #expect(citation.revision == request.hits[0].chunk.revision)
        #expect(citation.sourceDate == nil && citation.importedAt != nil) // import != decision/source date
        let destination = try await f.service.openCitation("S1", in: result)
        #expect(destination.hit.chunk == request.hits[0].chunk && destination.chunks.contains(request.hits[0].chunk))
        await #expect(throws: KnowledgeAnswerError.invalidCitation) { try await f.service.openCitation("S99", in: result) }
        _ = try await f.document("Релиз теперь в декабре", owners: [p.id, q.id], target: id)
        await #expect(throws: KnowledgeSearchError.sourceChanged) { try await f.service.openCitation("S1", in: result) }
        #expect(destination.chunks.contains { $0.text == "Релиз в ноябре" }) // returned snapshot is immutable
    }

    @Test(arguments: ["denied", "unknown"])
    func everyOwnerMustBeKnownAndAllowed(_ mode: String) async throws {
        let f = try QuestionFixture(); defer { f.cleanup() }
        let p = try await f.project(policy: .allowSelectedContext)
        let other = try await f.project("Закрытый", policy: .localOnly)
        let id = try await f.document(owners: [p.id, other.id])
        if mode == "unknown" {
            try f.sql("UPDATE document_projects SET project_id='\(UUID().uuidString)' WHERE document_id='\(id.uuidString)' AND project_id='\(other.id.uuidString)'")
            await #expect(throws: KnowledgeAnswerError.cloudNotAllowed) {
                try await f.service.prepare(question: "Релиз", projectID: p.id)
            }
        } else {
            let request = try await f.service.prepare(question: "Релиз", projectID: p.id)
            #expect(request.denied)
            await #expect(throws: KnowledgeAnswerError.cloudNotAllowed) { try await f.service.approve(request) }
            await #expect(throws: KnowledgeAnswerError.cloudNotAllowed) { try await f.service.answer(request) }
        }
        #expect(f.spy.calls == 0)
    }

    @Test(arguments: ["policy", "policyABA", "owners", "ownersABA", "revision", "deleted", "file", "recreate", "model", "modelABA"])
    func finalTransportGateRejectsChangesAfterConsent(_ change: String) async throws {
        let f = try QuestionFixture(); defer { f.cleanup() }
        let p = try await f.project(), other = try await f.project("Другой")
        let id = try await f.document(owners: [p.id])
        let request = try await f.service.prepare(question: "Релиз", projectID: p.id)
        let approval = try await f.service.approve(request)
        let hit = try #require(request.hits.first)
        f.spy.beforeGate = {
            switch change {
            case "policy", "policyABA":
                try await f.store.setCloudPolicy(.localOnly, for: p.id)
                if change == "policyABA" { try await f.store.setCloudPolicy(.askEveryTime, for: p.id) }
            case "owners", "ownersABA":
                try f.sql("INSERT INTO document_projects VALUES ('\(id.uuidString)', '\(other.id.uuidString)')")
                if change == "ownersABA" { try f.sql("DELETE FROM document_projects WHERE project_id='\(other.id.uuidString)'") }
            case "revision": _ = try await f.document("Релиз перенесён", owners: [p.id], target: id)
            case "deleted": try await f.store.removeEmbeddingSource(hit.source.key)
            case "file", "recreate":
                let file = try await f.importer.fileURL(for: try #require(hit.source.document))
                let bytes = try Data(contentsOf: file)
                if change == "recreate" { try FileManager.default.removeItem(at: file) }
                try (change == "file" ? Data("Подмена".utf8) : bytes).write(to: file, options: .atomic)
            case "model", "modelABA":
                try await f.store.activateEmbeddingModel(.init(id: "new-model", dimensions: 2))
                if change == "modelABA" { try f.sql("DELETE FROM embedding_active_model") }
            default: Issue.record("Unexpected fixture")
            }
        }
        do { _ = try await f.service.answer(request, consent: approval); Issue.record("Changed context was sent") }
        catch { #expect(error is KnowledgeSearchError || error is KnowledgeQuestionError) }
        #expect(f.spy.calls == 0)
    }

    @Test func consentIsSingleUseAndBoundToExactQuestionProjectAndService() async throws {
        let f = try QuestionFixture(); defer { f.cleanup() }
        let p = try await f.project(), q = try await f.project("Другой")
        _ = try await f.document(owners: [p.id, q.id])
        let a = try await f.service.prepare(question: "Релиз", projectID: p.id)
        let consent = try await f.service.approve(a)
        let b = try await f.service.prepare(question: "Когда релиз?", projectID: q.id)
        await #expect(throws: KnowledgeQuestionError.invalidConsent) { try await f.service.answer(b, consent: consent) }
        #expect(f.spy.calls == 0)
        let c = try await f.service.prepare(question: "Релиз", projectID: p.id)
        let fresh = try await f.service.approve(c)
        _ = try await f.service.answer(c, consent: fresh)
        await #expect(throws: KnowledgeQuestionError.invalidConsent) { try await f.service.answer(c, consent: fresh) }
        #expect(f.spy.calls == 1)
        let d = try await f.service.prepare(question: "Релиз", projectID: p.id)
        await #expect(throws: KnowledgeQuestionError.consentRequired) { try await f.service.answer(d) }
        let alien = KnowledgeQuestionService(store: f.store, search: f.search, meetingsRoot: f.root.appendingPathComponent("meetings"),
            documentsRoot: f.root.appendingPathComponent("copies"), client: f.spy, model: "test")
        await #expect(throws: KnowledgeQuestionError.superseded) { try await alien.answer(c, consent: fresh) }
        #expect(f.spy.calls == 1)
    }

    @Test(arguments: ["cancelBeforeSend", "cancelAfterSend", "switch", "taskCancel", "policyAfterSend"])
    func cancellationAndLateRepliesCannotPublish(_ action: String) async throws {
        let f = try QuestionFixture(); defer { f.cleanup() }
        let p = try await f.project(policy: .allowSelectedContext), q = try await f.project("Другой", policy: .allowSelectedContext)
        _ = try await f.document(owners: [p.id, q.id])
        let request = try await f.service.prepare(question: "Релиз", projectID: p.id)
        if action == "cancelBeforeSend" {
            f.spy.beforeGate = { f.service.cancel() }
        } else if action == "switch" {
            f.spy.afterSend = { _ = try? await f.service.prepare(question: "Релиз", projectID: q.id) }
        } else if action == "policyAfterSend" {
            f.spy.afterSend = { try? await f.store.setCloudPolicy(.localOnly, for: p.id) }
        } else if action == "cancelAfterSend" {
            f.spy.afterSend = { f.service.cancel() }
        } else {
            let entered = IndexGate(), release = IndexGate()
            f.spy.afterSend = { await entered.signal(); await release.wait() }
            let task = Task { try await f.service.answer(request) }
            await entered.wait(); task.cancel(); await release.signal()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(f.spy.calls == 1)
            return
        }
        do { _ = try await f.service.answer(request); Issue.record("Late reply escaped session fence") }
        catch { #expect(error is KnowledgeQuestionError) }
        #expect(f.spy.calls == (action == "cancelBeforeSend" ? 0 : 1))
    }

    @Test(arguments: ["invented", "missingInline", "invalid", "empty", "network", "noKey", "insufficient"])
    func answerValidationAndProviderErrorsAreExplicit(_ kind: String) async throws {
        let f = try QuestionFixture(); defer { f.cleanup() }
        let p = try await f.project(policy: .allowSelectedContext)
        _ = try await f.document(owners: [p.id])
        let request = try await f.service.prepare(question: "Релиз", projectID: p.id)
        switch kind {
        case "invented": f.spy.reply = #"{"answer":"Факт [S99].","sources":["S99"],"insufficientEvidence":false}"#
        case "missingInline": f.spy.reply = #"{"answer":"Без ссылки.","sources":["S1"],"insufficientEvidence":false}"#
        case "invalid": f.spy.reply = "не JSON"
        case "empty": f.spy.reply = #"{"answer":" ","sources":[],"insufficientEvidence":true}"#
        case "network": f.spy.failure = URLError(.notConnectedToInternet)
        case "noKey": f.spy.failure = LLMError.noAPIKey
        default: f.spy.reply = #"{"answer":"Нет сведений о сроке.","sources":[],"insufficientEvidence":true}"#
        }
        if kind == "insufficient" {
            let result = try await f.service.answer(request)
            #expect(result.answer.insufficientEvidence && result.answer.citations.isEmpty)
        } else {
            do { _ = try await f.service.answer(request); Issue.record("Expected explicit error") }
            catch {
                switch kind {
                case "network": #expect((error as? URLError)?.code == .notConnectedToInternet)
                case "noKey": #expect(error as? LLMError == .noAPIKey)
                case "invented", "missingInline": #expect(error as? KnowledgeAnswerError == .invalidCitation)
                default: #expect(error as? KnowledgeAnswerError == .invalidAnswer)
                }
            }
        }
        #expect(f.spy.calls == 1)
    }

    @Test(arguments: ["policy", "source", "cancel", "switch"])
    func changesDuringAsynchronousRetrievalCannotProduceReusablePreview(_ change: String) async throws {
        let entered = IndexGate(), release = IndexGate()
        let f = try QuestionFixture(query: { _ in
            await entered.signal(); await release.wait()
            throw LocalIndexingError.missingModel
        })
        defer { f.cleanup() }
        let p = try await f.project(), q = try await f.project("Другой")
        let id = try await f.document(owners: [p.id, q.id])
        try await f.store.activateEmbeddingModel(.init(id: "synthetic", dimensions: 2))
        let preparing = Task { try await f.service.prepare(question: "Релиз", projectID: p.id) }
        await entered.wait()
        switch change {
        case "policy": try await f.store.setCloudPolicy(.localOnly, for: p.id)
        case "source": _ = try await f.document("Релиз другая версия", owners: [p.id, q.id], target: id)
        case "cancel": f.service.cancel()
        default:
            // A new invalid query still replaces the UI session immediately.
            _ = try? await f.service.prepare(question: "", projectID: q.id)
        }
        await release.signal()
        do { _ = try await preparing.value; Issue.record("Stale preparation returned") }
        catch { #expect(error is KnowledgeQuestionError || error is KnowledgeSearchError) }
        #expect(f.spy.calls == 0)
    }

    @Test func meetingCitationKeepsExactReplicaAndRejectsTranscriptRecreation() async throws {
        let f = try QuestionFixture(); defer { f.cleanup() }
        let p = try await f.project(policy: .allowSelectedContext)
        let folder = f.root.appendingPathComponent("meetings/synthetic")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("transcript.json")
        let bytes = try JSONSerialization.data(withJSONObject: ["meetingId": "synthetic", "segments": [
            ["start": 42.5, "end": 55, "text": "Релиз в ноябре"]]])
        try bytes.write(to: file)
        _ = try await MeetingEmbeddingSnapshotReader(root: f.root.appendingPathComponent("meetings")).synchronize(meetingID: "synthetic", store: f.store)
        try await f.store.assignMeeting("synthetic", to: [p.id])
        let request = try await f.service.prepare(question: "Релиз", projectID: p.id)
        let result = try await f.service.answer(request)
        let opened = try await f.service.openCitation("S1", in: result)
        #expect(opened.hit.chunk.location.startSeconds == 42.5 && opened.hit.chunk.location.endSeconds == 55)
        #expect(result.answer.citations.first?.sourceRevision == opened.hit.source.observation.revision)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: file)
        await #expect(throws: KnowledgeSearchError.sourceChanged) { try await f.service.openCitation("S1", in: result) }
        #expect(f.spy.calls == 1)
    }

    @Test func emptyContextAndInvalidQueriesNeverReachTransportAndPreviewIsBounded() async throws {
        let f = try QuestionFixture(); defer { f.cleanup() }
        let p = try await f.project(policy: .allowSelectedContext)
        await #expect(throws: KnowledgeAnswerError.noContext) { try await f.service.prepare(question: "Релиз", projectID: p.id) }
        await #expect(throws: KnowledgeAnswerError.invalidQuestion) { try await f.service.prepare(question: " ", projectID: p.id) }
        await #expect(throws: KnowledgeSearchError.invalidQuery) { try await f.service.prepare(question: String(repeating: "я", count: 257), projectID: p.id) }
        for i in 0..<15 { _ = try await f.document("Релиз номер \(i)", owners: [p.id]) }
        let request = try await f.service.prepare(question: "Релиз", projectID: p.id)
        #expect(request.hits.count == 12 && request.searchResponse.hits.count == 15 && request.textCharacterCount <= 16_000)
        _ = try await f.service.answer(request)
        let json = try JSONSerialization.jsonObject(with: Data(try #require(f.spy.messages.last?.content).utf8)) as? [String: Any]
        #expect((json?["fragments"] as? [[String: Any]])?.count == 12)
    }
}

@MainActor @Suite struct QuestionFixtureLifecycleTests {
    private enum CallbackFailure: Error { case expected }
    private func exerciseCallback(_ mode: String) async throws {
        let f = try QuestionFixture(); defer { f.cleanup() }
        let project = try await f.project(policy: .allowSelectedContext)
        _ = try await f.document(owners: [project.id])
        let request = try await f.service.prepare(question: "Релиз", projectID: project.id)
        if mode == "throw" {
            f.spy.beforeGate = { _ = f.root; throw CallbackFailure.expected }
            _ = try await f.service.answer(request)
        } else {
            let entered = IndexGate(), release = IndexGate()
            // Deliberately capture the fixture and ignore cooperative cancellation.
            f.spy.afterSend = { _ = f.root; await entered.signal(); await release.wait() }
            let pending = Task { try await f.service.answer(request) }
            await entered.wait(); pending.cancel(); await release.signal()
            await #expect(throws: CancellationError.self) { try await pending.value }
        }
    }
    @Test(arguments: ["throw", "cancel"])
    func throwingAndCancelledCallbacksReleaseFixtureBeforeRootRemoval(_ mode: String) async throws {
        let scope = SQLiteFixtureScope(test: "question-callback-\(mode)")
        try await SQLiteFixtureScope.$current.withValue(scope) {
            try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
                if mode == "throw" {
                    await #expect(throws: CallbackFailure.expected) { try await exerciseCallback(mode) }
                } else { try await exerciseCallback(mode) }
                try await scope.finish()
            }
        }
        #expect(scope.trace.filter { $0["stage"] == "root-removed" && $0["exists"] == "false" }.count == 1)
        #expect(!scope.trace.contains { $0["stage"] == "sqlite-failure" || $0["stage"] == "teardown-timeout" })
    }
}
