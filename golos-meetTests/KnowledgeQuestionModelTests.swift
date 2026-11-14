import Foundation
import Testing
@testable import golos_meet

@MainActor private final class UIQuestionCompleter: ChatCompleter {
    var calls = 0
    var payload = ""
    var failure: Error?
    var reply = #"{"answer":"Релиз в ноябре [S1].","sources":["S1"],"insufficientEvidence":false}"#
    var waitAfterSend: (() async -> Void)?
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        try await dispatch(messages)
    }
    private func dispatch(_ messages: [ChatMessage]) async throws -> String {
        let scope = SQLiteFixtureScope.current
        scope?.note("question-ui-transport-enter")
        defer { scope?.note("question-ui-transport-returned") }
        calls += 1; payload = messages.last?.content ?? ""
        await waitAfterSend?()
        if let failure { throw failure }
        return reply
    }
}

/// Owned separately from the fixture: a cancelled model task may outlive it.
@MainActor private final class QuestionUICleanup {
    struct WeakSession { weak var value: KnowledgeQuestionService? }
    var sessions: [WeakSession] = []
    private var releases: [IndexGate] = []
    func own(_ gate: IndexGate) { releases.append(gate) }
    func releaseHeldOperations() async {
        let owned = releases; releases = []
        for gate in owned { await gate.signal() }
    }
}

@MainActor private final class QuestionUIFixture {
    let root: URL
    let store: ProjectStore
    let projects: ProjectLibrary
    let importer: DocumentImporter
    let search: KnowledgeSearchService
    let spy = UIQuestionCompleter()
    let model: KnowledgeQuestionModel
    let resources = QuestionUICleanup()
    init(query: @escaping KnowledgeSearchService.QueryEmbedding = { _ in throw LocalIndexingError.missingModel }, center: NotificationCenter? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("questions-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scope = try #require(SQLiteFixtureScope.current)
        scope.register(root: root)
        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        scope.register(store: store)
        projects = ProjectLibrary(store: store)
        importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
        search = KnowledgeSearchService(store: store, meetingsRoot: root.appendingPathComponent("meetings"), documentsRoot: root.appendingPathComponent("copies"), queryEmbedding: { text in
            scope.note("question-ui-retrieval-enter")
            defer { scope.note("question-ui-retrieval-returned") }
            return try await query(text)
        })
        let store = store, search = search, root = root, spy = spy, resources = resources
        model = KnowledgeQuestionModel(center: center) {
            let service = KnowledgeQuestionService(store: store, search: search, meetingsRoot: root.appendingPathComponent("meetings"),
                documentsRoot: root.appendingPathComponent("copies"), client: spy, model: "synthetic")
            resources.sessions.append(.init(value: service))
            return service
        }
        let model = model
        scope.onFinish { @MainActor [weak model, weak spy, weak scope] in
            model?.cancel(); spy?.waitAfterSend = nil
            scope?.note("question-ui-cancel-and-callback-release")
            await resources.releaseHeldOperations()
            scope?.note("question-ui-held-gates-released")
        }
    }
    func cleanup() {
        model.cancel(); spy.waitAfterSend = nil
        SQLiteFixtureScope.current?.note("question-ui-cancel-and-callback-release")
    }
    func ownRelease(_ gate: IndexGate) { resources.own(gate) }
    func reopenedStore() -> ProjectStore {
        let reopened = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        SQLiteFixtureScope.current?.register(store: reopened)
        return reopened
    }
    func setup(policy: ProjectCloudPolicy = .askEveryTime, sharedPolicy: ProjectCloudPolicy? = nil) async throws -> UUID {
        let p = try await store.createProject(name: "Север")
        try await store.setCloudPolicy(policy, for: p.id)
        var owners: Set<UUID> = [p.id]
        if let sharedPolicy {
            let q = try await store.createProject(name: "Лира")
            try await store.setCloudPolicy(sharedPolicy, for: q.id); owners.insert(q.id)
        }
        let file = root.appendingPathComponent("План.txt")
        try Data("Релиз состоится в ноябре. Перед запуском нужна проверка нагрузки.".utf8).write(to: file)
        _ = try await importer.importFile(id: UUID(), url: file, projectIDs: owners) { _ in }
        await projects.reload(); model.projectID = p.id; model.question = "Когда релиз?"
        return p.id
    }
    func settle() async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.busy)
    }
}

@MainActor @Suite(SQLiteFixtureTrait()) struct KnowledgeQuestionModelTests {
    @Test func actualModelPreparesLocallyThenExplicitConsentSendsAndSourceOpensWithoutAutoplay() async throws {
        let f = try QuestionUIFixture(); defer { f.cleanup() }
        let p = try await f.setup()
        f.model.prepare(); try await f.settle()
        #expect(f.model.phase == .prepared && f.spy.calls == 0)
        let request = try #require(f.model.request)
        #expect(request.approvalProjectIDs == [p] && request.hits.count == 1)
        #expect(request.searchResponse.semanticMessage != nil) // lexical works with no model
        f.model.send(); try await f.settle()
        #expect(f.model.phase == .answered && f.spy.calls == 1)
        #expect(try await f.store.snapshot().projects.first?.cloudPolicy == .askEveryTime)
        f.model.send(); #expect(f.spy.calls == 1) // cannot replay this request
        f.model.open("S1"); try await f.settle()
        #expect(f.model.destination?.chunks.contains { $0.text.contains("ноябре") } == true)
        f.model.back(); #expect(f.model.destination == nil && f.model.phase == .answered)
        f.model.question = "Другой вопрос"
        #expect(f.model.result == nil && f.model.request == nil && f.model.phase == .idle)
    }

    @Test func localOnlyOwnerCannotBeOverriddenAndOnlyExplicitSettingsChangeIsPersisted() async throws {
        let f = try QuestionUIFixture(); defer { f.cleanup() }
        _ = try await f.setup(policy: .allowSelectedContext, sharedPolicy: .localOnly)
        f.model.prepare(); try await f.settle()
        #expect(f.model.request?.denied == true && !f.model.canSend)
        f.model.send(); #expect(f.spy.calls == 0)
        let other = try #require(f.projects.projects.first { $0.name == "Лира" })
        try await f.projects.setCloudPolicy(.askEveryTime, for: other.id)
        f.model.cancel(); f.model.prepare(); try await f.settle()
        #expect(f.model.request?.approvalProjectIDs == [other.id])
        f.model.send(); try await f.settle()
        #expect(f.spy.calls == 1 && f.model.phase == .answered)
        #expect(try await f.reopenedStore().snapshot().projects.first { $0.id == other.id }?.cloudPolicy == .askEveryTime)
    }

    @Test func longQuestionIsKeptWholeAndExplicitShortSearchIsRequiredLocally() async throws {
        let f = try QuestionUIFixture(); defer { f.cleanup() }
        _ = try await f.setup()
        let question = String(repeating: "Прошу учесть историю встреч и все решения. ", count: 12) + "Когда релиз?"
        f.model.question = question
        #expect(f.model.needsRetrievalQuery && !f.model.canPrepare)
        f.model.prepare(); #expect(f.model.phase == .idle && f.spy.calls == 0)
        f.model.retrievalQuery = "релиз ноябрь"
        f.model.prepare(); try await f.settle()
        #expect(f.model.request?.question == question)
        f.model.send(); try await f.settle()
        let payload = try JSONSerialization.jsonObject(with: Data(f.spy.payload.utf8)) as? [String: Any]
        #expect(payload?["question"] as? String == question)
        f.model.question = String(repeating: "а", count: 4001)
        #expect(!f.model.canPrepare && f.model.result == nil)
    }

    @Test(arguments: ["project", "question", "search", "cancel"])
    func delayedReplyCannotReappearAfterUIChange(_ action: String) async throws {
        let f = try QuestionUIFixture(); defer { f.cleanup() }
        _ = try await f.setup()
        let entered = IndexGate(), release = IndexGate()
        f.ownRelease(release)
        f.spy.waitAfterSend = { await entered.signal(); await release.wait() }
        f.model.prepare(); try await f.settle(); f.model.send(); await entered.wait()
        switch action {
        case "project": f.model.projectID = UUID()
        case "question": f.model.question += " Новый вопрос"
        case "search": f.model.retrievalQuery = "Другие слова"
        default: f.model.cancel()
        }
        #expect(f.model.result == nil && f.model.request == nil && !f.model.busy)
        await release.signal()
        // Allow the uncancellable fake response to cross postflight before asserting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.model.result == nil && f.model.destination == nil && f.model.phase != .answered)
        #expect(f.spy.calls == 1)
    }

    @Test func delayedRetrievalAndIndexEventsAreAlsoFenced() async throws {
        let entered = IndexGate(), release = IndexGate(), center = NotificationCenter()
        let f = try QuestionUIFixture(query: { _ in await entered.signal(); await release.wait(); throw LocalIndexingError.missingModel }, center: center)
        defer { f.cleanup() }
        f.ownRelease(release)
        _ = try await f.setup()
        try await f.store.activateEmbeddingModel(.init(id: "synthetic", dimensions: 2))
        f.model.prepare(); await entered.wait()
        f.model.projectID = nil
        await release.signal(); try await Task.sleep(for: .milliseconds(50))
        #expect(f.model.request == nil && f.spy.calls == 0)
        f.model.projectID = f.projects.projects.first?.id
        f.model.prepare(); try await f.settle()
        #expect(f.model.phase == .prepared)
        KnowledgeIndexEvents.post(.model, center: center)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.model.notice?.kind == .stale && f.model.request == nil)
    }

    @Test(arguments: ["noKey", "network", "invalid", "invented", "empty", "insufficient"])
    func errorsAndInsufficientEvidenceHaveExplicitStateAndRetryPreparesNewConsent(_ type: String) async throws {
        let f = try QuestionUIFixture(); defer { f.cleanup() }
        _ = try await f.setup()
        switch type {
        case "noKey": f.spy.failure = LLMError.noAPIKey
        case "network": f.spy.failure = URLError(.notConnectedToInternet)
        case "invalid": f.spy.reply = "invalid JSON"
        case "invented": f.spy.reply = #"{"answer":"Нет [S99]","sources":["S99"],"insufficientEvidence":false}"#
        case "empty": f.spy.reply = ""
        default: f.spy.reply = #"{"answer":"Недостаточно сведений о решении.","sources":[],"insufficientEvidence":true}"#
        }
        f.model.prepare(); try await f.settle()
        let original = f.model.request?.id
        f.model.send(); try await f.settle()
        if type == "insufficient" { #expect(f.model.result?.answer.insufficientEvidence == true) }
        else {
            #expect(f.model.phase == .failed && f.model.result == nil && f.model.request == nil)
            #expect(f.model.notice?.kind == (type == "noKey" ? .key : type == "network" ? .network : .invalid))
            f.spy.failure = nil; f.spy.reply = #"{"answer":"Релиз [S1]","sources":["S1"],"insufficientEvidence":false}"#
            f.model.prepare(); try await f.settle()
            #expect(f.model.request?.id != original && f.spy.calls == 1)
            f.model.send(); try await f.settle()
            #expect(f.model.phase == .answered && f.spy.calls == 2)
        }
    }

    @Test func failedOpeningClearsOldAnswerInsteadOfPresentingChangedSource() async throws {
        let f = try QuestionUIFixture(); defer { f.cleanup() }
        _ = try await f.setup(); f.model.prepare(); try await f.settle(); f.model.send(); try await f.settle()
        let version = try #require(f.model.request?.hits.first?.source.document)
        let file = try await f.importer.fileURL(for: version)
        try Data("Подмена источника".utf8).write(to: file, options: .atomic)
        f.model.open("S1"); try await f.settle()
        #expect(f.model.result == nil && f.model.destination == nil && f.model.notice?.kind == .stale)
        #expect(f.spy.calls == 1)
    }
}

@MainActor private final class QuestionUIWitness {
    weak var fixture: QuestionUIFixture?
    weak var model: KnowledgeQuestionModel?
    weak var spy: UIQuestionCompleter?
    weak var store: ProjectStore?
    var resources: QuestionUICleanup?
    var root: URL?
    func track(_ fixture: QuestionUIFixture) {
        self.fixture = fixture; model = fixture.model; spy = fixture.spy; store = fixture.store
        resources = fixture.resources; root = fixture.root
    }
    func lateWrite(_ scope: SQLiteFixtureScope) async {
        scope.note("question-ui-late-write-enter")
        #expect(root.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        do {
            let store = try #require(store)
            _ = try await store.createProject(name: "Synthetic noncooperative late write")
            #expect(try await store.snapshot().projects.count == 2)
            scope.note("question-ui-late-write-finished")
        } catch { Issue.record(error) }
    }
}

@MainActor @Suite struct QuestionUIFixtureLifecycleTests {
    private enum BodyError: Error { case sentinel }
    private func heldBody(kind: String, exit: String, scope: SQLiteFixtureScope, witness: QuestionUIWitness,
                          entered: IndexGate, release: IndexGate, tail: IndexGate) async throws {
        let f: QuestionUIFixture
        if kind == "query" {
            f = try QuestionUIFixture(query: { _ in
                await entered.signal(); await release.wait()
                await witness.lateWrite(scope)
                await tail.wait()
                throw LocalIndexingError.missingModel
            }, center: NotificationCenter())
        } else { f = try QuestionUIFixture(center: NotificationCenter()) }
        witness.track(f); f.ownRelease(release)
        _ = try await f.setup()
        let reopened = f.reopenedStore()
        #expect(try await reopened.snapshot().projects.count == 1)
        if kind == "query" {
            try await f.store.activateEmbeddingModel(.init(id: "synthetic", dimensions: 2))
            f.model.prepare()
        } else {
            // Deliberate fixture→spy→callback→fixture cycle; the running call
            // keeps its copy after cleanup clears the stored callback.
            f.spy.waitAfterSend = { [f] in
                await entered.signal(); await release.wait()
                await witness.lateWrite(scope)
                await tail.wait()
                #expect(f.model.result == nil)
            }
            f.model.prepare(); try await f.settle(); f.model.send()
        }
        await entered.wait()
        if exit == "cancel" { withUnsafeCurrentTask { $0?.cancel() }; try Task.checkCancellation() }
        if exit == "throw" { throw BodyError.sentinel }
        // No end-of-success cleanup here: onFinish must handle all three exits.
    }
    @Test(arguments: ["response", "query"], ["return", "throw", "cancel"])
    func heldNoncooperativeOperationsAndCallbackCyclesFinishBeforeUnlink(kind: String, exit: String) async throws {
        let scope = SQLiteFixtureScope(test: "question-ui-held-\(kind)-\(exit)"), witness = QuestionUIWitness()
        let entered = IndexGate(), release = IndexGate(), tail = IndexGate()
        try await SQLiteFixtureScope.$current.withValue(scope) {
            try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
                let result = await Task { () -> Result<Void, any Error> in
                    do { try await heldBody(kind: kind, exit: exit, scope: scope, witness: witness, entered: entered, release: release, tail: tail); return .success(()) }
                    catch { return .failure(error) }
                }.value
                let root = try #require(witness.root)
                let cleanup = Task { try await scope.finish() }
                // Load-tolerant completion budget (60s, pattern of #61/#88):
                // the late write is expected to finish, never timed for speed.
                let deadline = ContinuousClock.now + .seconds(60)
                while !scope.trace.contains(where: { $0["stage"] == "question-ui-late-write-finished" }), ContinuousClock.now < deadline { await Task.yield() }
                #expect(scope.trace.contains { $0["stage"] == "question-ui-late-write-finished" })
                #expect(FileManager.default.fileExists(atPath: root.path))
                #expect(!scope.trace.contains { $0["stage"] == "root-removed" })
                #expect(witness.model != nil && witness.model?.busy == false && witness.model?.result == nil)
                #expect(witness.resources?.sessions.contains { $0.value != nil } == true)
                #expect(scope.trace.filter { $0["stage"] == "opened" }.count == 2)
                #expect(scope.trace.filter { $0["stage"] == "closed" }.count == 1)
                await tail.signal(); try await cleanup.value
                #expect(!FileManager.default.fileExists(atPath: root.path))
                #expect(witness.fixture == nil && witness.model == nil && witness.spy == nil && witness.store == nil)
                #expect(witness.resources?.sessions.allSatisfy { $0.value == nil } == true)
                #expect(scope.trace.filter { $0["stage"] == "closed" && $0["result"] == "0" }.count == 2)
                #expect(!scope.trace.contains { $0["stage"] == "sqlite-failure" })
                if exit == "cancel" { #expect(throws: CancellationError.self) { try result.get() } }
                else if exit == "throw" { #expect(throws: BodyError.sentinel) { try result.get() } }
                else { try result.get() }
            }
        }
    }
    private func completedCycle(_ witness: QuestionUIWitness) async throws {
        let f = try QuestionUIFixture()
        witness.track(f); _ = try await f.setup()
        f.spy.waitAfterSend = { [f] in #expect(f.model.busy) }
        f.model.prepare(); try await f.settle(); f.model.send(); try await f.settle()
        #expect(f.model.phase == .answered && f.spy.calls == 1)
    }
    @Test func storedCallbackCycleIsReleasedEvenAfterOperationAlreadyFinished() async throws {
        let scope = SQLiteFixtureScope(test: "question-ui-completed-cycle"), witness = QuestionUIWitness()
        try await SQLiteFixtureScope.$current.withValue(scope) {
            try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
                try await completedCycle(witness)
                #expect(witness.fixture != nil) // cycle is real before cleanup
                try await scope.finish()
                #expect(witness.fixture == nil && witness.model == nil && witness.spy == nil && witness.store == nil)
                #expect(witness.resources?.sessions.allSatisfy { $0.value == nil } == true)
                #expect(scope.trace.filter { $0["stage"] == "closed" && $0["result"] == "0" }.count == 1)
                #expect(scope.trace.contains { $0["stage"] == "root-removed" && $0["exists"] == "false" })
            }
        }
    }
}
