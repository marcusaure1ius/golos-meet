import Foundation
@MainActor final class InputKeySpy: ChatCompleter {
    var calls = 0
    var reply = ""
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        await sent()
    }
    func sent() -> String { calls += 1; return reply }
}
@main @MainActor struct InputKeyProbe {
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() async throws {
        let original = URL(fileURLWithPath: "/tmp/review52-38615DAF-9944-410D-8D57-317BFA8E8A9A")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("review52-input-fix-\(UUID())")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let url = copy.appendingPathComponent("knowledge.sqlite")
        try FileManager.default.copyItem(at: original.appendingPathComponent("knowledge.sqlite"), to: url)
        let db = try ProjectDatabase(url: url), store = ProjectStore(url: url)
        let project = UUID(uuidString: try db.rows("SELECT id FROM projects WHERE name='Recipient'")[0][0])!
        let parentID = UUID(uuidString: try db.rows("SELECT id FROM memory_events WHERE json_extract(body,'$.statement.subject')='parent'")[0][0])!
        let originalIDs = try db.rows("SELECT id FROM memory_events WHERE project_id=?", bindings: [project.uuidString]).map { $0[0] }
        check(originalIDs.count == 1)
        // Original driver intentionally ended after replacing the index model.
        // Restore synthetic readiness only in this copy, never the original DB.
        let indexModel = EmbeddingIndexModel(id: "synthetic2D-review52", dimensions: 2)
        try await store.activateEmbeddingModel(indexModel)
        while let lease = try await store.claimEmbeddingJob() {
            let vectors = try lease.snapshot.chunks.map { IndexedChunkVectors(chunkID: $0.id, bodyTokenCount: 1, windows: [.init(tokenStart: 0, tokenCount: 1, vector: try KnowledgeVector(modelID: indexModel.id, values: [1, 0]))]) }
            let published = try await store.publishEmbeddingVectors(vectors, lease: lease); check(published)
        }
        let search = KnowledgeSearchService(store: store, meetingsRoot: original.appendingPathComponent("meetings"), documentsRoot: original.appendingPathComponent("copies"), queryEmbedding: { _ in throw LocalIndexingError.missingModel })
        let hits = try await search.search("релиз", scope: .project(project)).hits
        let a = hits.first { $0.chunk.text.contains("RAW_A_SELECTED") }!, b = hits.first { $0.chunk.text.contains("RAW_B_PREVIOUSLY_HIDDEN") }!
        let spy = InputKeySpy()
        func service() -> ProjectMemoryUpdateService { .init(store: ProjectStore(url: url), meetingsRoot: original.appendingPathComponent("meetings"), documentsRoot: original.appendingPathComponent("copies"), client: spy, model: "synthetic-extractor52") }
        func reply(_ name: String, _ quote: String) throws -> String {
            let fact: [String: Any] = ["subject": name, "kind": "agreement", "conditions": [:], "text": name, "action": "assertion", "decisionDate": NSNull(), "deadline": NSNull(), "evidence": [["source": "S1", "quote": quote]], "links": []]
            return String(decoding: try JSONSerialization.data(withJSONObject: ["facts": [fact], "insufficientEvidence": false]), as: UTF8.self)
        }
        let firstService = service(), first = try await firstService.prepare(projectID: project, hits: [a], parentEventIDs: [parentID])
        check(!first.payload.contains("RAW_B_PREVIOUSLY_HIDDEN"))
        spy.reply = try reply("fixed-A", "RAW_A_SELECTED")
        let firstConsent = try await firstService.approve(first)
        guard case .published(let one) = try await firstService.update(first, consent: firstConsent) else { fatalError() }
        let secondService = service(), second = try await secondService.prepare(projectID: project, hits: [b], parentEventIDs: [parentID])
        check(first.consumedSources == second.consumedSources && first.payload != second.payload)
        spy.reply = try reply("fixed-B", "RAW_B_PREVIOUSLY_HIDDEN")
        let secondConsent = try await secondService.approve(second)
        guard case .published(let two) = try await secondService.update(second, consent: secondConsent) else { fatalError() }
        check(Set(one.eventIDs).isDisjoint(with: two.eventIDs) && spy.calls == 2)
        let restarted = service(), replay = try await restarted.prepare(projectID: project, hits: [b], parentEventIDs: [parentID])
        let replayConsent = try await restarted.approve(replay)
        let repeated = try await restarted.update(replay, consent: replayConsent)
        check(repeated == .published(.unchanged(two.eventIDs)) && spy.calls == 2)
        let retained = try db.rows("SELECT id FROM memory_events WHERE project_id=?", bindings: [project.uuidString]).map { $0[0] }
        check(retained.count == 3 && originalIDs.allSatisfy { retained.contains($0) })
        let batches = try db.rows("SELECT producer_key,fingerprint FROM memory_batches WHERE project_id=? AND producer_key LIKE 'memory-update-input-v2:%'", bindings: [project.uuidString])
        check(batches.count == 2 && Set(batches.map { $0[1] }).count == 1)
        print("PASS actual reviewer legacy DB copy: selected A+M and B+M have same full closure, different payloads and IDs; 2 network spy calls, restart exact B replay adds 0 calls; original legacy event retained. Copy: \(copy.path)")
    }
}
