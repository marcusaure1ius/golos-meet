import Foundation
import Testing
@testable import golos_meet

@MainActor private final class MemoryFixture {
    let root: URL
    let store: ProjectStore
    let service: ProjectMemoryHistoryService
    let importer: DocumentImporter
    let search: KnowledgeSearchService
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-history-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scope = try #require(SQLiteFixtureScope.current)
        scope.register(root: root)
        store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        scope.register(store: store)
        importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
        service = ProjectMemoryHistoryService(store: store, meetingsRoot: root.appendingPathComponent("meetings"), documentsRoot: root.appendingPathComponent("copies"))
        search = KnowledgeSearchService(store: store, meetingsRoot: root.appendingPathComponent("meetings"), documentsRoot: root.appendingPathComponent("copies"), queryEmbedding: { _ in throw LocalIndexingError.missingModel })
    }
    func cleanup() { SQLiteFixtureScope.current?.note("history-fixture-body-cleanup") }
    func project(_ name: String = "Север", policy: ProjectCloudPolicy = .allowSelectedContext) async throws -> UUID {
        let p = try await store.createProject(name: name); try await store.setCloudPolicy(policy, for: p.id); return p.id
    }
    func meeting(_ id: String, text: String, owners: Set<UUID>) async throws -> URL {
        let folder = root.appendingPathComponent("meetings/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("transcript.json")
        try JSONSerialization.data(withJSONObject: ["meetingId":id,"segments":[["start":42.5,"end":55,"text":text]]]).write(to: file, options:.atomic)
        _ = try await MeetingEmbeddingSnapshotReader(root: root.appendingPathComponent("meetings")).synchronize(meetingID: id, store: store)
        try await store.assignMeeting(id, to: owners)
        return file
    }
    func document(_ text: String, owners: Set<UUID>, target: UUID? = nil) async throws -> UUID {
        let file = root.appendingPathComponent("\(UUID()).txt"); try Data(text.utf8).write(to: file)
        return try await importer.importFile(id: UUID(), url: file, projectIDs: owners, targetID: target) { _ in }.documentID
    }
    func hit(_ externalID: String, project: UUID, query: String = "релиз") async throws -> KnowledgeSearchHit {
        try #require(try await search.search(query, scope:.project(project)).hits.first { $0.source.key.externalID == externalID })
    }
    func draft(_ hit: KnowledgeSearchHit, text: String = "Релиз 26 ноября", from: String = "2026-11-26", through: String? = nil,
               conditions: [String:String] = ["environment":"production"], kind: MemoryFactKind = .deadline) -> MemoryDraft {
        let start = Self.day(from), end = Self.day(through ?? from)
        return .init(statement:.init(subject:"release:sever",kind:kind,conditions:conditions,text:text,
                                    deadline:kind == .deadline ? .init(earliest:start,latest:end) : nil), evidenceChunkIDs:[hit.id])
    }
    func seedCandidates(_ count: Int, project: UUID, hit: KnowledgeSearchHit) async throws -> [UUID] {
        var ids: [UUID] = []
        for offset in stride(from: 0, to: count, by: 32) {
            let lease = try await service.begin(projectID: project, producerKey: "budget-seed-\(offset)", hits: [hit])
            let drafts = (offset..<min(offset + 32, count)).map { draft(hit, text: "Договорённость \($0)", kind: .agreement) }
            ids += try await service.publish(drafts, lease: lease).eventIDs
        }
        return ids
    }
    func activeCandidates() throws -> Int {
        let db = try ProjectDatabase(url: root.appendingPathComponent("knowledge.sqlite"))
        let value = try #require(db.rows("SELECT COUNT(*) FROM memory_events e WHERE json_extract(e.body,'$.action')='assertion' AND NOT EXISTS (SELECT 1 FROM memory_links l WHERE l.target_id=e.id AND l.kind IN ('replaces','retracts','corrects'))").first?.first)
        return try #require(Int(value))
    }
    func journalSnapshot() throws -> [String: [[String]]] {
        let db = try ProjectDatabase(url: root.appendingPathComponent("knowledge.sqlite"))
        return try Dictionary(uniqueKeysWithValues: ["memory_state", "memory_events", "memory_links", "memory_head_versions", "memory_batches", "sqlite_sequence"].map { table in
            (table, try db.rows("SELECT * FROM \(table)").sorted { $0.joined(separator: "|") < $1.joined(separator: "|") })
        })
    }
    /// Synthetic reproduction of the exact v7 state admitted by the old API.
    /// Only append: keep the journal immutable and all provenance intact.
    func appendLegacy257th(copying id: UUID) async throws -> UUID {
        let old = try await store.memoryEvent(id)
        let event = MemoryEvent(id: UUID(), projectID: old.projectID, origin: .model, action: .assertion,
            statement: old.statement, evidenceChunkIDs: old.evidenceChunkIDs, parentEventIDs: old.parentEventIDs,
            sources: old.sources, ownerProjectIDs: old.ownerProjectIDs, decisionDate: old.decisionDate, extractedAt: Date())
        let slot = try MemoryEncoding.slot(event.statement)
        let db = try ProjectDatabase(url: root.appendingPathComponent("knowledge.sqlite"))
        try db.execute("PRAGMA foreign_keys=ON")
        try db.transaction {
            let active = try db.rows("SELECT e.id FROM memory_events e WHERE e.project_id=? AND e.slot=? AND NOT EXISTS (SELECT 1 FROM memory_links l WHERE l.target_id=e.id AND l.kind IN ('replaces','retracts','corrects'))", bindings: [old.projectID.uuidString, slot])
            try #require(active.count == 256)
            try db.execute("INSERT INTO memory_events(id,project_id,slot,body) VALUES (?,?,?,?)", bindings: [event.id.uuidString, event.projectID.uuidString, slot, try MemoryEncoding.encode(event)])
            for row in active { try db.execute("INSERT INTO memory_links VALUES (?,?,'related')", bindings: [event.id.uuidString, row[0]]) }
            try db.execute("INSERT INTO memory_head_versions(project_id,slot,event_id,manual) VALUES (?,?,?,0)", bindings: [event.projectID.uuidString, slot, event.id.uuidString])
            try db.execute("INSERT INTO memory_batches VALUES (?,?,?,?)", bindings: [event.projectID.uuidString, "legacy-257", "synthetic-old-api-state", try MemoryEncoding.encode([event.id])])
            try db.execute("UPDATE memory_state SET revision=revision+1,generation=? WHERE project_id=?", bindings: [UUID().uuidString, event.projectID.uuidString])
        }
        return event.id
    }
    static func day(_ value: String) -> Date { ISO8601DateFormatter().date(from:value+"T00:00:00Z")! }
}

@MainActor @Suite(SQLiteFixtureTrait()) struct ProjectMemoryHistoryTests {
    @Test func sequentialMeetingsKeepBothDatedAssertionsAndRealStructuredDeadlineConflict() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }
        let p = try await f.project()
        _ = try await f.meeting("one",text:"Релиз согласован на 26 ноября.",owners:[p])
        let first = try await f.hit("one",project:p)
        let a = try await f.service.begin(projectID:p,producerKey:"extract-v1",hits:[first])
        var draft = f.draft(first); draft.decisionDate = MemoryFixture.day("2026-10-30")
        let firstID = try #require(try await f.service.publish([draft],lease:a,extractedAt:MemoryFixture.day("2026-11-01")).eventIDs.first)
        _ = try await f.meeting("two",text:"Релиз перенесли на 5 декабря.",owners:[p])
        let second = try await f.hit("two",project:p)
        let b = try await f.service.begin(projectID:p,producerKey:"extract-v1",hits:[second])
        let secondID = try #require(try await f.service.publish([f.draft(second,text:"Релиз 5 декабря",from:"2026-12-05")],lease:b).eventIDs.first)
        let history = try await f.service.history(projectID:p)
        #expect(history.entries.map { $0.event.id } == [secondID,firstID])
        let original = try #require(history.entries.last?.event)
        #expect(original.sources.first?.key.externalID == "one" && original.sources.first?.chunk.location.startSeconds == 42.5)
        #expect(original.decisionDate == MemoryFixture.day("2026-10-30") && original.extractedAt == MemoryFixture.day("2026-11-01"))
        #expect(original.sources.first?.sourceDate == nil && original.sources.first?.document == nil)
        let head = try #require(try await f.service.heads(projectID:p).heads.first)
        #expect(head.entry.event.id == secondID && head.conflictingEventIDs == [firstID] && !head.usableAsCurrent)
        let db = try ProjectDatabase(url:f.root.appendingPathComponent("knowledge.sqlite"))
        #expect(try db.rows("SELECT kind FROM memory_links WHERE event_id=? AND target_id=?",bindings:[secondID.uuidString,firstID.uuidString]) == [["conflicts"]])
    }

    @Test(arguments:["overlap","differentConditions","freeText"])
    func compatibleRangesConditionsAndWordingAreNotInventedConflicts(_ mode:String) async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }; let p = try await f.project()
        _ = try await f.meeting("one",text:"Релиз планируется в ноябре.",owners:[p])
        let h1 = try await f.hit("one",project:p)
        let a = try await f.service.begin(projectID:p,producerKey:"extract-v1",hits:[h1])
        let kind:MemoryFactKind = mode == "freeText" ? .agreement : .deadline
        _ = try await f.service.publish([f.draft(h1,text:"Первое условие",from:"2026-11-01",through:"2026-11-30",kind:kind)],lease:a)
        _ = try await f.meeting("two",text:"Релиз 26 ноября после проверки.",owners:[p])
        let h2 = try await f.hit("two",project:p)
        let b = try await f.service.begin(projectID:p,producerKey:"extract-v1",hits:[h2])
        let conditions = mode == "differentConditions" ? ["environment":"pilot"] : ["environment":"production"]
        _ = try await f.service.publish([f.draft(h2,text:"Совместимое уточнение",conditions:conditions,kind:kind)],lease:b)
        let heads = try await f.service.heads(projectID:p)
        #expect(heads.heads.allSatisfy { $0.conflictingEventIDs.isEmpty && $0.usableAsCurrent })
        #expect(heads.heads.count == (mode == "differentConditions" ? 2 : 1))
    }

    @Test func explicitReplacementRetainsOldClaimAndCompletionClaimDoesNotChangeExternalOrLocalTask() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }; let p = try await f.project()
        _ = try await f.meeting("one",text:"Релиз: договорились о ноябре.",owners:[p])
        let h1 = try await f.hit("one",project:p)
        let a = try await f.service.begin(projectID:p,producerKey:"extract-v1",hits:[h1])
        let old = try #require(try await f.service.publish([f.draft(h1)],lease:a).eventIDs.first)
        _ = try await f.meeting("two",text:"Релиз: новое решение заменяет прежний срок; я сделал проверку.",owners:[p])
        let h2 = try await f.hit("two",project:p)
        let b = try await f.service.begin(projectID:p,producerKey:"extract-v1",hits:[h2])
        var replacement = f.draft(h2,from:"2026-12-05"); replacement.links = [.init(targetID:old,kind:.replaces)]
        let done = MemoryDraft(statement:.init(subject:"check:load",kind:.completionClaim,conditions:[:],text:"Участник заявил: я сделал проверку"),evidenceChunkIDs:[h2.id])
        _ = try await f.service.publish([replacement,done],lease:b)
        let history = try await f.service.history(projectID:p)
        #expect(history.entries.count == 3 && history.entries.last?.supersededBy.count == 1)
        #expect(history.entries.contains { $0.event.statement.kind == .completionClaim })
        #expect(try await f.service.heads(projectID:p).heads.allSatisfy(\.usableAsCurrent))
        #expect(try await f.store.snapshot().meetingProjects["two"] == [p])
        #expect(try await f.store.memoryEvent(old).statement.deadline?.earliest == MemoryFixture.day("2026-11-26"))
    }

    @Test func manualCorrectionSurvivesRestartReindexReplayAndNewModelVersionWithCompleteLineage() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }
        let p = try await f.project(), q = try await f.project("Приватный",policy:.localOnly)
        let doc = try await f.document("Релиз в ноябре",owners:[p,q]); let hit = try await f.hit(doc.uuidString,project:p)
        let firstLease = try await f.service.begin(projectID:p,producerKey:"extract-v1",hits:[hit])
        let original = try #require(try await f.service.publish([f.draft(hit)],lease:firstLease).eventIDs.first)
        let intent = UUID(), manualLease = try await f.service.beginCorrection(eventID:original,intentID:intent)
        let correction = f.draft(hit,text:"Ручное уточнение: 28 ноября",from:"2026-11-28")
        let manual = try #require(try await f.service.publish([correction],lease:manualLease).eventIDs.first)
        let restartedStore = ProjectStore(url:f.root.appendingPathComponent("knowledge.sqlite"))
        let restarted = ProjectMemoryHistoryService(store:restartedStore,meetingsRoot:f.root.appendingPathComponent("meetings"),documentsRoot:f.root.appendingPathComponent("copies"))
        #expect(try await restarted.heads(projectID:p).heads.first?.entry.event.id == manual)
        let repeatedCorrection = try await restarted.beginCorrection(eventID:original,intentID:intent)
        #expect(try await restarted.publish([correction],lease:repeatedCorrection) == .unchanged([manual]))
        try await restartedStore.requestEmbeddingReindex(hit.source.key)
        let fresh = try await f.hit(doc.uuidString,project:p)
        let replay = try await restarted.begin(projectID:p,producerKey:"extract-v1",hits:[fresh])
        #expect(try await restarted.publish([f.draft(fresh)],lease:replay) == .unchanged([original]))
        let newModel = try await restarted.begin(projectID:p,producerKey:"extract-v2",hits:[fresh])
        _ = try await restarted.publish([f.draft(fresh)],lease:newModel)
        let head = try #require(try await restarted.heads(projectID:p).heads.first)
        #expect(head.manualSelection && head.entry.event.id == manual && head.entry.event.statement.text.contains("Ручное"))
        let proof = try await restarted.provenance(eventID:manual)
        #expect(Set(proof.events.map(\.id)) == [original,manual] && proof.ownerProjectIDs == [p,q])
        #expect(!KnowledgeEgress.permitsGeneration(ownerProjectIDs:proof.ownerProjectIDs,projects:proof.knownProjects))
        #expect(try await restarted.history(projectID:p).entries.count == 3)
    }

    @Test func derivedCrossProjectAndManualTextCannotHideOriginalOwnerEvenAfterRemovalOrDeletion() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }
        let p = try await f.project(), q = try await f.project("Запрещённый",policy:.localOnly), r = try await f.project("Другой")
        let doc = try await f.document("Релиз в ноябре",owners:[p,q]), h = try await f.hit(doc.uuidString,project:p)
        let a = try await f.service.begin(projectID:p,producerKey:"extract-v1",hits:[h])
        let first = try #require(try await f.service.publish([f.draft(h)],lease:a).eventIDs.first)
        let b = try await f.service.begin(projectID:r,producerKey:"derived-v1",hits:[],parentEventIDs:[first])
        let derived = try #require(try await f.service.publish([f.draft(h,text:"Конспект для другого проекта")],lease:b).eventIDs.first)
        let c = try await f.service.beginCorrection(eventID:derived,intentID:UUID())
        let corrected = try #require(try await f.service.publish([f.draft(h,text:"Ручная формулировка")],lease:c).eventIDs.first)
        var proof = try await f.service.provenance(eventID:corrected)
        #expect(proof.events.count == 3 && proof.sources.count == 1 && proof.ownerProjectIDs == [p,q,r])
        #expect(!KnowledgeEgress.permitsGeneration(ownerProjectIDs:proof.ownerProjectIDs,projects:proof.knownProjects))
        let db = try ProjectDatabase(url:f.root.appendingPathComponent("knowledge.sqlite"))
        try db.execute("DELETE FROM document_projects WHERE project_id=?",bindings:[q.uuidString])
        try db.execute("DELETE FROM projects WHERE id=?",bindings:[q.uuidString])
        proof = try await f.service.provenance(eventID:corrected)
        #expect(proof.ownerProjectIDs.contains(q) && proof.missingOwnerProjectIDs == [q] && proof.evidenceState != .current)
        #expect(!KnowledgeEgress.permitsGeneration(ownerProjectIDs:proof.ownerProjectIDs,projects:proof.knownProjects))
        #expect(try await f.service.history(projectID:r).entries.count == 2)
    }

    @Test(arguments:["newLease","catalogABA","fileABA","fileRecreate","missingFile","revision","owners","projectABA"])
    func delayedPublicationCannotReplaceNewStateAndStoredHistoryBecomesNoncurrent(_ change:String) async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }; let p = try await f.project()
        let file = try await f.meeting("one",text:"Релиз в ноябре",owners:[p]), h = try await f.hit("one",project:p)
        let seed = try await f.service.begin(projectID:p,producerKey:"seed",hits:[h])
        let original = try #require(try await f.service.publish([f.draft(h)],lease:seed).eventIDs.first)
        let late = try await f.service.begin(projectID:p,producerKey:"late",hits:[h])
        let bytes = try Data(contentsOf:file)
        switch change {
        case "newLease":
            let newer = try await f.service.begin(projectID:p,producerKey:"newer",hits:[h])
            _ = try await f.service.publish([f.draft(h,text:"Новая обработка")],lease:newer)
        case "catalogABA":
            try await f.store.removeEmbeddingSource(h.source.key)
            _ = try await MeetingEmbeddingSnapshotReader(root:f.root.appendingPathComponent("meetings")).synchronize(meetingID:"one",store:f.store)
        case "fileABA":
            try Data("temporary".utf8).write(to:file); try bytes.write(to:file)
        case "fileRecreate":
            try FileManager.default.removeItem(at:file); try bytes.write(to:file)
        case "missingFile": try FileManager.default.removeItem(at:file)
        case "revision": _ = try await f.meeting("one",text:"Релиз в декабре",owners:[p])
        case "owners": try await f.store.assignMeeting("one",to:[])
        default:
            let db = try ProjectDatabase(url:f.root.appendingPathComponent("knowledge.sqlite"))
            try db.execute("DELETE FROM projects WHERE id=?",bindings:[p.uuidString])
            try db.execute("INSERT INTO projects VALUES (?, 'Recreated', NULL, 'allowSelectedContext')",bindings:[p.uuidString])
        }
        do { _ = try await f.service.publish([f.draft(h,text:"Запоздавший результат")],lease:late); Issue.record("Late publication accepted") }
        catch { #expect(error is ProjectMemoryError) }
        let history = try await f.service.history(projectID:p)
        #expect(history.entries.contains { $0.event.id == original })
        #expect(!history.entries.contains { $0.event.statement.text == "Запоздавший результат" })
        if !["newLease","projectABA"].contains(change) {
            #expect(history.entries.allSatisfy { $0.evidenceState != .current })
            #expect(try await f.service.heads(projectID:p).heads.allSatisfy { !$0.usableAsCurrent })
        }
    }

    @Test func retractionIsVisibleHistoryButNotACurrentPositiveFactAndModelCannotRetireManualSelection() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }; let p = try await f.project()
        _ = try await f.meeting("one",text:"Релиз в ноябре",owners:[p]); let h = try await f.hit("one",project:p)
        let a = try await f.service.begin(projectID:p,producerKey:"seed",hits:[h])
        let original = try #require(try await f.service.publish([f.draft(h)],lease:a).eventIDs.first)
        let manualLease = try await f.service.beginCorrection(eventID:original,intentID:UUID())
        let manual = try #require(try await f.service.publish([f.draft(h,text:"Ручной срок")],lease:manualLease).eventIDs.first)
        let automatic = try await f.service.begin(projectID:p,producerKey:"auto-replace",hits:[h])
        var bad = f.draft(h); bad.links = [.init(targetID:manual,kind:.replaces)]
        await #expect(throws:ProjectMemoryError.invalid) { try await f.service.publish([bad],lease:automatic) }
        #expect(try await f.service.heads(projectID:p).heads.first?.entry.event.id == manual)
        let explicit = try await f.service.beginCorrection(eventID:manual,intentID:UUID())
        let withdrawn = MemoryDraft(statement:.init(subject:"release:sever",kind:.deadline,conditions:["environment":"production"],text:"Пользователь отменил срок"),evidenceChunkIDs:[h.id],links:[.init(targetID:manual,kind:.retracts)],action:.retraction)
        _ = try await f.service.publish([withdrawn],lease:explicit)
        let head = try #require(try await f.service.heads(projectID:p).heads.first)
        #expect(head.manualSelection && head.entry.event.action == .retraction && !head.usableAsCurrent)
        #expect(try await f.service.history(projectID:p).entries.count == 3)
    }

    @Test func selectionReadCannotReturnAnOlderHeadAfterConcurrentPublication() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }; let p = try await f.project()
        _ = try await f.meeting("one",text:"Релиз в ноябре",owners:[p]); let h = try await f.hit("one",project:p)
        let first = try await f.service.begin(projectID:p,producerKey:"v1",hits:[h])
        _ = try await f.service.publish([f.draft(h)],lease:first)
        let selected = try await f.store.memoryHeadRows(projectID:p,limit:100)
        // The filesystem validation awaits another actor. A concurrent local
        // publication can replace a head even with identical source bytes.
        let second = try await f.service.begin(projectID:p,producerKey:"v2",hits:[h])
        _ = try await f.service.publish([f.draft(h,text:"Уточнённая формулировка")],lease:second)
        await #expect(throws:ProjectMemoryError.stale) {
            try await f.store.memoryHeadStatus(projectID:p,expectedVersions:selected.map { $0.0 },events:selected.map { $0.2 },limit:100)
        }
        #expect(try await f.service.heads(projectID:p).heads.first?.entry.event.statement.text == "Уточнённая формулировка")
    }

    @Test func cancelledPublicationDoesNotAppendAnyHistoryOrSelection() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }; let p = try await f.project()
        _ = try await f.meeting("one",text:"Релиз в ноябре",owners:[p]); let h = try await f.hit("one",project:p)
        let lease = try await f.service.begin(projectID:p,producerKey:"seed",hits:[h])
        let release = IndexGate()
        let pending = Task { await release.wait(); return try await f.service.publish([f.draft(h)],lease:lease) }
        pending.cancel(); await release.signal()
        await #expect(throws:CancellationError.self) { try await pending.value }
        let history = try await f.service.history(projectID:p)
        let heads = try await f.service.heads(projectID:p)
        #expect(history.entries.isEmpty && heads.heads.isEmpty)
    }

    @Test func finalCandidateBudgetAllows256Rejects257AndRollsBackAnOverflowLateInBatch() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }; let p = try await f.project()
        _ = try await f.meeting("one", text: "Релиз в ноябре", owners: [p]); let h = try await f.hit("one", project: p)
        _ = try await f.seedCandidates(255, project: p, hit: h)
        #expect(try f.activeCandidates() == 255)
        let lease = try await f.service.begin(projectID: p, producerKey: "overflow-batch", hits: [h])
        let before = try f.journalSnapshot()
        let candidate = f.draft(h, text: "Новый кандидат", kind: .agreement)
        // First draft reaches 256; second must roll back its predecessor's
        // event, links, selection and AUTOINCREMENT, not only reject itself.
        await #expect(throws: ProjectMemoryError.limited) { try await f.service.publish([candidate, candidate], lease: lease) }
        #expect(try f.journalSnapshot() == before)
        let last = try await f.service.publish([candidate], lease: lease).eventIDs
        #expect(try f.activeCandidates() == 256)
        let replay = try await f.service.begin(projectID: p, producerKey: "overflow-batch", hits: [h])
        #expect(try await f.service.publish([candidate], lease: replay) == .unchanged(last))
        let full = try await f.service.begin(projectID: p, producerKey: "257th", hits: [h])
        let fullSnapshot = try f.journalSnapshot()
        await #expect(throws: ProjectMemoryError.limited) { try await f.service.publish([candidate], lease: full) }
        #expect(try f.journalSnapshot() == fullSnapshot)
    }

    @Test func manualCorrectionAndRetractionWorkAt256WithoutLosingPrecedenceOrBudget() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }; let p = try await f.project()
        _ = try await f.meeting("one", text: "Релиз в ноябре", owners: [p]); let h = try await f.hit("one", project: p)
        let ids = try await f.seedCandidates(256, project: p, hit: h), original = try #require(ids.last)
        let correcting = try await f.service.beginCorrection(eventID: original, intentID: UUID())
        let manual = try #require(try await f.service.publish([f.draft(h, text: "Ручной выбор", kind: .agreement)], lease: correcting).eventIDs.first)
        #expect(try f.activeCandidates() == 256)
        #expect(try await f.service.heads(projectID: p).heads.first?.entry.event.id == manual)
        let automatic = try await f.service.begin(projectID: p, producerKey: "cannot-retire-manual", hits: [h])
        var forbidden = f.draft(h, kind: .agreement); forbidden.links = [.init(targetID: manual, kind: .replaces)]
        await #expect(throws: ProjectMemoryError.invalid) { try await f.service.publish([forbidden], lease: automatic) }
        let retracting = try await f.service.beginCorrection(eventID: manual, intentID: UUID())
        let retraction = MemoryDraft(statement: .init(subject: "release:sever", kind: .agreement, conditions: ["environment": "production"], text: "Пользователь отменил утверждение"), evidenceChunkIDs: [h.id], links: [.init(targetID: manual, kind: .retracts)], action: .retraction)
        let withdrawn = try #require(try await f.service.publish([retraction], lease: retracting).eventIDs.first)
        #expect(try f.activeCandidates() == 255)
        let refill = try await f.service.begin(projectID: p, producerKey: "refill", hits: [h])
        _ = try await f.service.publish([f.draft(h, kind: .agreement)], lease: refill)
        #expect(try f.activeCandidates() == 256)
        let head = try #require(try await f.service.heads(projectID: p).heads.first)
        #expect(head.entry.event.id == withdrawn && head.manualSelection && !head.usableAsCurrent)
        #expect(try await f.store.memoryEvent(original).statement.text == "Договорённость 255")
    }

    @Test(arguments: ["correction", "retraction"])
    func legacy257CanRecoverByExplicitManualRetirementsWithoutDiscardingHistory(_ mode: String) async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }; let p = try await f.project()
        _ = try await f.meeting("one", text: "Релиз в ноябре", owners: [p]); let h = try await f.hit("one", project: p)
        let ids = try await f.seedCandidates(256, project: p, hit: h)
        let legacy = try await f.appendLegacy257th(copying: try #require(ids.last))
        #expect(try f.activeCandidates() == 257)
        let lease = try await f.service.beginCorrection(eventID: legacy, intentID: UUID())
        let before = try f.journalSnapshot()
        let corrected = f.draft(h, text: "Явное уточнение", kind: .agreement)
        await #expect(throws: ProjectMemoryError.limited) { try await f.service.publish([corrected], lease: lease) }
        #expect(try f.journalSnapshot() == before)
        var recovery = corrected
        if mode == "correction" {
            // Duplicate labels must not be counted as extra retirements.
            recovery.links = [.init(targetID: legacy, kind: .replaces), .init(targetID: legacy, kind: .replaces)]
            await #expect(throws: ProjectMemoryError.limited) { try await f.service.publish([recovery], lease: lease) }
            #expect(try f.journalSnapshot() == before)
            recovery.links = [.init(targetID: try #require(ids.first), kind: .replaces)]
        } else {
            recovery = MemoryDraft(statement: .init(subject: "release:sever", kind: .agreement, conditions: ["environment": "production"], text: "Явная отмена"), evidenceChunkIDs: [h.id], links: [.init(targetID: legacy, kind: .retracts)], action: .retraction)
        }
        let result = try #require(try await f.service.publish([recovery], lease: lease).eventIDs.first)
        #expect(try f.activeCandidates() == 256)
        let db = try ProjectDatabase(url: f.root.appendingPathComponent("knowledge.sqlite"))
        #expect(try db.rows("SELECT COUNT(*) FROM memory_events") == [["258"]])
        #expect(try await f.store.memoryEvent(legacy).id == legacy)
        let history = try await f.service.history(projectID: p)
        #expect(history.entries.first?.event.id == result)
        #expect(history.entries.first(where: { $0.event.id == legacy })?.supersededBy.contains(result) == true)
        let head = try #require(try await f.service.heads(projectID: p).heads.first)
        #expect(head.manualSelection && head.entry.event.id == result && head.usableAsCurrent == (mode == "correction"))
        #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
    }

    @Test func invalidBatchRollsBackAllRowsAndImmutableJournalAndPaginationAreReal() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }; let p = try await f.project()
        _ = try await f.meeting("one",text:"Релиз в ноябре",owners:[p]); let h = try await f.hit("one",project:p)
        let lease = try await f.service.begin(projectID:p,producerKey:"extract-v1",hits:[h])
        let invalid = MemoryDraft(statement:.init(subject:"release:sever",kind:.deadline,conditions:[:],text:"Некорректный диапазон",deadline:.init(earliest:MemoryFixture.day("2026-12-01"),latest:MemoryFixture.day("2026-11-01"))),evidenceChunkIDs:[h.id])
        await #expect(throws:ProjectMemoryError.invalid) { try await f.service.publish([f.draft(h),invalid],lease:lease) }
        #expect(try await f.service.history(projectID:p).entries.isEmpty)
        let first = try #require(try await f.service.publish([f.draft(h)],lease:lease).eventIDs.first)
        let manual = try await f.service.beginCorrection(eventID:first,intentID:UUID())
        _ = try await f.service.publish([f.draft(h,text:"Исправлено")],lease:manual)
        let one = try await f.service.history(projectID:p,limit:1)
        let cursor = try #require(one.nextBeforeSequence)
        let two = try await f.service.history(projectID:p,beforeSequence:cursor,limit:1)
        #expect(two.entries.first?.event.id == first && two.nextBeforeSequence == nil)
        let scope = try #require(SQLiteFixtureScope.current)
        let (db, connection) = try scope.openConnection(at: f.root.appendingPathComponent("knowledge.sqlite"))
        scope.expectingFailure(connection: connection, phase: .step, operation: .update, result: 19, extended: 1811) {
            #expect(throws:ProjectStoreError.self) { try db.execute("UPDATE memory_events SET body='{}'") }
        }
        scope.expectingFailure(connection: connection, phase: .step, operation: .delete, result: 19, extended: 1811) {
            #expect(throws:ProjectStoreError.self) { try db.execute("DELETE FROM memory_events") }
        }
        #expect(try await f.service.history(projectID:p).entries.count == 2)
    }
}

@MainActor @Suite struct MemoryHistoryFixtureLifecycleTests {
    private enum BodyFailure: Error { case expected }
    private func throwAfterOpeningHistory() async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }
        _ = try await f.project()
        throw BodyFailure.expected
    }
    @Test func throwingHistoryBodyPreservesErrorAndClosesStoreBeforeUnlink() async throws {
        let scope = SQLiteFixtureScope(test: "history-throw-control")
        try await SQLiteFixtureScope.$current.withValue(scope) {
            try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
                await #expect(throws: BodyFailure.expected) { try await throwAfterOpeningHistory() }
                try await scope.finish()
            }
        }
        #expect(scope.trace.contains { $0["stage"] == "closed" && $0["result"] == "0" })
        #expect(scope.trace.contains { $0["stage"] == "root-removed" && $0["exists"] == "false" })
    }
    private func produceExpectedForeignAndLateFaults(_ scope: SQLiteFixtureScope) async throws {
        let f = try MemoryFixture(); defer { f.cleanup() }
        let p = try await f.project()
        _ = try await f.meeting("one", text: "Релиз в ноябре", owners: [p])
        let hit = try await f.hit("one", project: p)
        let lease = try await f.service.begin(projectID: p, producerKey: "fault-boundary-control", hits: [hit])
        _ = try await f.service.publish([f.draft(hit)], lease: lease)
        let url = f.root.appendingPathComponent("knowledge.sqlite")
        let (owner, connection) = try scope.openConnection(at: url)
        let (foreign, _) = try scope.openConnection(at: url)
        scope.expectingFailure(connection: connection, phase: .step, operation: .update, result: 19, extended: 1811) {
            // Same file, statement and code, but this connection is not authorized.
            #expect(throws: ProjectStoreError.self) { try foreign.execute("UPDATE memory_events SET body='{}'") }
            #expect(throws: ProjectStoreError.self) { try owner.execute("UPDATE memory_events SET body='{}'") }
        }
        // The same owner's error outside the asserted operation must also fail teardown.
        #expect(throws: ProjectStoreError.self) { try owner.execute("UPDATE memory_events SET body='{}'") }
        #expect(try await f.service.history(projectID: p).entries.count == 1)
    }
    @Test func exactJournalFaultDoesNotAuthorizeForeignConnectionOrLaterError() async throws {
        let scope = SQLiteFixtureScope(test: "fault-boundary-control")
        try await SQLiteFixtureScope.$current.withValue(scope) {
            try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
                try await produceExpectedForeignAndLateFaults(scope)
                // This is the explicit negative control: native resources still
                // close and unlink, while the two unexpected diagnostics fail it.
                await #expect(throws: SQLiteFixtureScope.FixtureError.sqliteFailures) { try await scope.finish() }
            }
        }
        #expect(scope.trace.filter { $0["stage"] == "sqlite-failure" }.count == 3)
        #expect(scope.trace.filter { $0["stage"] == "expected-sqlite-failure" }.count == 1)
        #expect(scope.trace.contains { $0["stage"] == "root-removed" && $0["exists"] == "false" })
    }
}
