import Foundation
import SwiftUI
import AppKit
import CryptoKit
import Combine
import Testing
@testable import golos_meet

@MainActor private final class MemoryPanelFixture {
    let base: UpdateFixture
    let worker: ProjectMemoryQueueWorker
    let model: ProjectMemoryPanelModel
    init() throws {
        base = try UpdateFixture()
        worker = .init(store:base.store,meetingsRoot:base.root.appendingPathComponent("meetings"),documentsRoot:base.root.appendingPathComponent("copies"),client:base.spy,model:"fake-only")
        model = .init(store:base.store,worker:worker,meetingsRoot:base.root.appendingPathComponent("meetings"),documentsRoot:base.root.appendingPathComponent("copies"))
        let base = base
        base.spy.afterAttempt = { [weak base] _ in
            guard let base else { return }
            let json = try #require(try JSONSerialization.jsonObject(with:Data(base.spy.payload.utf8)) as? [String:Any])
            let fragments = try #require(json["fragments"] as? [[String:Any]])
            let text = try #require(fragments.first?["text"] as? String)
            var facts: [[String:Any]]
            if text.contains("2026-11-26") || text.contains("2026-12-05") {
                facts = [base.fact(text.contains("2026-12-05") ? "2026-12-05" : "2026-11-26")]
                if text.contains("сделал проверку") { var done = base.fact("сделал проверку",kind:"completionClaim"); done["subject"] = "check:load"; facts.append(done) }
            } else {
                facts = [["subject":"fact:" + MemoryEncoding.hash(text),"kind":"agreement","conditions":[:],"text":text,"action":"assertion","deadline":NSNull(),"decisionDate":NSNull(),"evidence":[["source":"S1","quote":text]],"links":[]]]
            }
            base.spy.reply = try base.response(facts)
        }
        // Independent weak captures still reach base when a callback keeps only
        // base alive, or when an overridden callback captures the whole fixture.
        // Do not wait here for a gated adapter: scope release hooks run next,
        // then native close is witnessed before root removal by the trait.
        let worker = worker, model = model
        SQLiteFixtureScope.current?.onFinish { @MainActor [weak base, weak worker, weak model] in
            model?.close(); base?.cleanup()
            await worker?.stop()
            SQLiteFixtureScope.current?.note("panel-scope-stop-requested")
        }
    }
    func releaseOnFinish(_ gate: IndexGate) {
        SQLiteFixtureScope.current?.onFinish { await gate.signal() }
    }
    func track(_ panel: ProjectMemoryPanelModel) {
        SQLiteFixtureScope.current?.onFinish { @MainActor [weak panel] in panel?.close() }
    }
    func open(_ project: UUID) async throws { model.projectID = project; try await settle() }
    func settle(_ selected:ProjectMemoryPanelModel? = nil) async throws {
        let target = selected ?? model
        let limit = ContinuousClock.now + .seconds(8)
        while target.busy || target.loading {
            guard ContinuousClock.now < limit else { throw MemoryQueueError.busy }
            try await Task.sleep(for:.milliseconds(5))
        }
        if target.request != nil { await worker.waitUntilIdle() }
    }
    func job(_ source: String) async throws -> MemoryQueueJob { try #require(try await base.store.memoryQueueSnapshot().jobs.first { $0.source.externalID == source && (model.projectID == nil || $0.projectID == model.projectID) }) }
    func cleanup() async { model.close(); await worker.stop(); await worker.waitUntilIdle(); base.cleanup() }
}

@MainActor @Suite(SQLiteFixtureTrait()) struct ProjectMemoryPanelTests {
    @Test func readOnlyOverviewShowsConflictsClaimsAndUnknownDatesWithoutChangingGeneration() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project()
        try await f.base.meeting("one",text:"Релиз 2026-11-26",owners:[p])
        await f.worker.start(); await f.worker.waitUntilIdle()
        try await f.base.meeting("two",text:"Релиз 2026-12-05. Я сделал проверку.",owners:[p])
        await f.worker.changed(); await f.worker.waitUntilIdle(); await f.worker.stop()
        let db = try ProjectDatabase(url:f.base.root.appendingPathComponent("knowledge.sqlite"))
        let versions = try db.rows("SELECT * FROM memory_state ORDER BY project_id")
        try await f.open(p)
        #expect(f.model.heads.count == 2 && f.model.history.count == 3 && f.model.queue.jobs.allSatisfy(\.completeCoverage))
        #expect(f.model.heads.contains { $0.head?.conflictingEventIDs.isEmpty == false && !$0.usable })
        #expect(f.model.heads.contains { $0.entry.event.statement.kind == .completionClaim })
        #expect(f.model.history.allSatisfy { $0.entry.event.decisionDate == nil && $0.entry.event.sources.allSatisfy { $0.sourceDate == nil } })
        #expect(try db.rows("SELECT * FROM memory_state ORDER BY project_id") == versions)
        #expect(f.base.spy.calls == 2)
        await f.cleanup()
    }

    @Test func exactConsentUsesRealQueueAndSourceOpensCheckedSnapshotWithoutPlayer() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(policy:.askEveryTime)
        let doc = try await f.base.document(owners:[p]); await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
        f.model.prepare(try await f.job(doc.uuidString)); try await f.settle()
        let request = try #require(f.model.request)
        #expect(request.approvalProjectIDs == [p] && request.fragments.count == 1 && f.base.spy.calls == 0)
        f.model.send(); try await f.settle(); await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 1 && f.base.spy.payload == request.payload)
        #expect(try await f.job(doc.uuidString).completeCoverage)
        f.model.send(); #expect(f.base.spy.calls == 1)
        let event = try #require(f.model.heads.first?.entry.event)
        f.model.inspect(event); try await f.settle()
        let source = try #require(f.model.inspected?.sources.first)
        f.model.open(source); try await f.settle()
        #expect(f.model.destination?.hit.chunk == source.chunk)
        #expect(f.model.destination?.chunks.contains(source.chunk) == true)
        f.model.back(); #expect(f.model.destination == nil)
        await f.cleanup()
    }

    @Test func allOwnerDenialCannotBeOverriddenAndFreshPreviewRequiredAfterPolicyChange() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(policy:.askEveryTime), q = try await f.base.project("Приватный",policy:.localOnly)
        let doc = try await f.base.document(owners:[p,q]); await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
        #expect(f.model.queue.jobs.allSatisfy { $0.projectID == p && $0.state == .denied })
        f.model.prepare(try await f.job(doc.uuidString)); try await f.settle(); f.model.send()
        #expect(f.base.spy.calls == 0 && f.model.request == nil)
        try await f.base.store.setCloudPolicy(.askEveryTime,for:q); await f.worker.changed(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        f.model.prepare(try await f.job(doc.uuidString)); try await f.settle()
        #expect(f.model.request?.ownerProjectIDs == [p,q] && f.model.request?.approvalProjectIDs == [p,q])
        try await f.base.store.setCloudPolicy(.localOnly,for:q)
        f.model.send(); try await f.settle()
        #expect(f.base.spy.calls == 0)
        await f.cleanup()
    }

    @Test func queryProjectAndFileChangesFencePreparedActionsWithoutTransport() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(policy:.askEveryTime), q = try await f.base.project("Пустой")
        let doc = try await f.base.document(owners:[p]); await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
        f.model.prepare(try await f.job(doc.uuidString)); try await f.settle(); f.model.filter = "новый фильтр"; f.model.send()
        #expect(f.model.request == nil && f.base.spy.calls == 0)
        f.model.filter = ""; f.model.prepare(try await f.job(doc.uuidString)); try await f.settle()
        try await f.open(q); f.model.send(); #expect(f.base.spy.calls == 0 && f.model.heads.isEmpty)
        try await f.open(p); f.model.prepare(try await f.job(doc.uuidString)); try await f.settle()
        let request = try #require(f.model.request), version = try #require(request.fragments.first?.source.document)
        let url = try await f.base.importer.fileURL(for:version)
        try Data("Изменено на диске".utf8).write(to:url,options:.atomic)
        f.model.send(); try await f.settle()
        #expect(f.base.spy.calls == 0 && f.model.request == nil)
        await f.cleanup()
    }

    @Test func manualCorrectionAndRetractionKeepHistoryAndManualPrecedence() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project()
        _ = try await f.base.document(owners:[p]); await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
        let original = try #require(f.model.heads.first?.entry.event)
        f.model.prepareCorrection(original,text:"Релиз подтверждён вручную",retract:false,earliest:f.base.day("2026-12-05"),latest:f.base.day("2026-12-05"),decision:nil)
        try await f.settle(); #expect(f.model.correction?.event.id == original.id && f.base.spy.calls == 1)
        f.model.publishCorrection(); try await f.settle(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        let manual = try #require(f.model.heads.first?.entry.event)
        #expect(manual.origin == .manual && f.model.heads.first?.head?.manualSelection == true)
        #expect(manual.statement.deadline?.earliest == f.base.day("2026-12-05") && manual.decisionDate == nil)
        f.model.prepareCorrection(manual,text:"Срок больше не действует",retract:true,earliest:nil,latest:nil,decision:nil)
        try await f.settle(); f.model.publishCorrection(); try await f.settle(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        let history = try await f.base.history.history(projectID:p)
        #expect(history.entries.contains { $0.event.id == original.id })
        #expect(history.entries.contains { $0.event.action == .retraction && $0.event.origin == .manual })
        #expect(f.model.heads.allSatisfy { !$0.usable })
        #expect(f.base.spy.calls == 1)
        await f.cleanup()
    }

    @Test func manualPreviewCASRejectsJournalChangeInsteadOfOverwritingIt() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project()
        let doc = try await f.base.document(owners:[p]); await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
        let original = try #require(f.model.heads.first?.entry.event)
        f.model.prepareCorrection(original,text:"Старое подготовленное исправление",retract:false,earliest:original.statement.deadline?.earliest,latest:original.statement.deadline?.latest,decision:nil)
        try await f.settle(); #expect(f.model.correction != nil)
        let hit = try await f.base.hit(doc.uuidString,project:p), lease = try await f.base.history.begin(projectID:p,producerKey:"external",hits:[hit])
        _ = try await f.base.history.publish([.init(statement:.init(subject:"other",kind:.agreement,conditions:[:],text:"Новая версия"),evidenceChunkIDs:[hit.id])],lease:lease)
        f.model.publishCorrection(); try await f.settle()
        let events = try await f.base.history.history(projectID:p)
        #expect(events.entries.count == 2 && !events.entries.contains { $0.event.statement.text == "Старое подготовленное исправление" })
        #expect(f.model.correction == nil && f.model.stale)
        await f.cleanup()
    }

    @Test func staleIntermediateCanBeInspectedAndExplicitlyRetractedThenRawQueueRecovers() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(), q = try await f.base.project("Предок")
        try await f.base.meeting("a",text:"Релиз ANCESTOR",owners:[q]); let a = try await f.base.hit("a",project:q)
        let seed = try await f.base.history.begin(projectID:q,producerKey:"a",hits:[a])
        let ancestor = try #require(try await f.base.history.publish([.init(statement:.init(subject:"plan",kind:.agreement,conditions:[:],text:"ANCESTOR"),evidenceChunkIDs:[a.id])],lease:seed).eventIDs.first)
        try await f.base.meeting("d",text:"Релиз MIDDLE",owners:[p]); let d = try await f.base.hit("d",project:p)
        let seedD = try await f.base.history.begin(projectID:p,producerKey:"d",hits:[d],parentEventIDs:[ancestor])
        let middle = try #require(try await f.base.history.publish([.init(statement:.init(subject:"middle",kind:.agreement,conditions:[:],text:"MIDDLE"),evidenceChunkIDs:[d.id])],lease:seedD).eventIDs.first)
        try await f.base.meeting("b",text:"Релиз RAW_B",owners:[p]); await f.worker.changed()
        for source in ["a","d"] { try await f.base.store.cancelMemoryQueue(try await f.job(source).sequence) }
        await f.worker.start(); await f.worker.waitUntilIdle()
        let db = try ProjectDatabase(url:f.base.root.appendingPathComponent("knowledge.sqlite"))
        let oldEvents = try db.rows("SELECT id,body FROM memory_events ORDER BY sequence"), oldBatches = try db.rows("SELECT * FROM memory_queue_batches")
        let retire = try await f.base.history.begin(projectID:q,producerKey:"retire-a",hits:[a],parentEventIDs:[ancestor])
        let retirement = try #require(try await f.base.history.publish([.init(statement:.init(subject:"plan",kind:.agreement,conditions:[:],text:"Отменено модельным источником"),evidenceChunkIDs:[a.id],links:[.init(targetID:ancestor,kind:.retracts)],action:.retraction)],lease:retire).eventIDs.first)
        await f.worker.changed(); await f.worker.waitUntilIdle(); try await f.open(p)
        #expect(try await f.job("b").state == .stale && f.base.spy.calls == 1)
        let stale = try #require(f.model.heads.first { $0.id == middle })
        #expect(!stale.usable && stale.ancestry == .stale)
        f.model.inspect(stale.entry.event); try await f.settle()
        #expect(f.model.inspectedState == .stale && f.model.inspected?.events.contains { $0.id == ancestor } == true)
        #expect(f.model.retiredEvents.contains(ancestor))
        let linked = try #require(f.model.relatedEvents.first { $0.id == retirement })
        f.model.inspectRelated(linked); try await f.settle()
        #expect(f.model.inspected?.rootEventID == retirement)
        f.model.inspect(stale.entry.event); try await f.settle()
        f.model.prepareCorrection(stale.entry.event,text:"Устаревший промежуточный вывод отменён после проверки",retract:true,earliest:nil,latest:nil,decision:nil)
        try await f.settle(); #expect(f.model.correction != nil)
        f.model.publishCorrection(); try await f.settle(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        #expect(try await f.job("b").completeCoverage)
        #expect(f.base.spy.calls == 2 && !f.base.spy.payload.contains("MIDDLE") && !f.base.spy.payload.contains("ANCESTOR"))
        #expect(try db.rows("SELECT id,body FROM memory_events ORDER BY sequence").starts(with:oldEvents))
        #expect(try db.rows("SELECT * FROM memory_queue_batches").contains { oldBatches.contains($0) })
        await f.cleanup()
    }

    @Test func lateNoncooperativeSendCannotPublishAfterProjectSwitch() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(policy:.askEveryTime), q = try await f.base.project("Пустой")
        let doc = try await f.base.document(owners:[p]), entered = IndexGate(), release = IndexGate()
        let original = f.base.spy.afterAttempt
        f.releaseOnFinish(release)
        f.base.spy.afterAttempt = { attempt in try await original?(attempt); await entered.signal(); await release.wait() }
        await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
        f.model.prepare(try await f.job(doc.uuidString)); try await f.settle(); f.model.send(); await entered.wait()
        f.model.projectID = q; await release.signal(); try await f.settle(); await f.worker.waitUntilIdle()
        #expect(f.model.projectID == q && f.model.request == nil && f.model.heads.isEmpty)
        #expect(try await f.base.history.history(projectID:p).entries.isEmpty)
        #expect(f.base.spy.calls == 1)
        await f.cleanup()
    }

    @Test func oldVersionSourceCannotReopenAsCurrentAndProjectChangeDropsOldSourceAction() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(), q = try await f.base.project("Пустой")
        let doc = try await f.base.document(owners:[p]); await f.worker.start(); await f.worker.waitUntilIdle(); await f.worker.stop(); try await f.open(p)
        let event = try #require(f.model.heads.first?.entry.event)
        f.model.inspect(event); try await f.settle(); let source = try #require(f.model.inspected?.sources.first)
        _ = try await f.base.document("Релиз 2026-12-05",owners:[p],target:doc)
        f.model.open(source); try await f.settle()
        #expect(f.model.destination == nil && f.model.stale)
        try await f.open(q); f.model.open(source); f.model.inspect(event)
        #expect(f.model.destination == nil && f.model.inspected == nil)
        await f.cleanup()
    }

    @Test func scopedSnapshotAndPagedHistoryDoNotClaimWholeArchiveCoverage() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(), q = try await f.base.project("Другой")
        let doc = try await f.base.document(owners:[p]), other = try await f.base.document("Релиз OTHER",owners:[q])
        let h = try await f.base.hit(doc.uuidString,project:p)
        for batch in 0..<2 {
            let lease = try await f.base.history.begin(projectID:p,producerKey:"page-\(batch)",hits:[h])
            _ = try await f.base.history.publish((0..<30).map { .init(statement:.init(subject:"s-\(batch)-\($0)",kind:.agreement,conditions:[:],text:"Факт \(batch)-\($0)"),evidenceChunkIDs:[h.id]) },lease:lease)
        }
        await f.worker.changed(); try await f.open(p)
        #expect(f.model.history.count == 50 && f.model.older != nil && f.model.headsLimited)
        f.model.reload(before:f.model.older); try await f.settle(); #expect(f.model.history.count == 10 && f.model.older == nil && f.model.page != nil)
        try await f.open(q)
        #expect(f.model.queue.jobs.count == 1 && f.model.queue.jobs.first?.source.externalID == other.uuidString)
        #expect(f.base.spy.calls == 0)
        await f.cleanup()
    }
}

@MainActor extension ProjectMemoryPanelTests {
    @Test func renderActualNativePanelStatesWhenExplicitlyRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_MEMORY_PANEL"], !output.isEmpty else { return }
        let root = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let f = try MemoryPanelFixture(), p = try await f.base.project(policy:.askEveryTime), empty = try await f.base.project("Пустой")
        let library = ProjectLibrary(store:f.base.store); await library.reload()
        let doc = try await f.base.document(owners:[p]); await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
        var manifest:[[String:Any]] = []
        func capture(_ name:String, tab:String = "Обзор", height:Int = 1200) throws {
            for dark in [false,true] {
                let palette = dark ? Palette.dark : Palette.light
                let content = ProjectMemoryPanel(model:f.model,initialTab:tab).environmentObject(library)
                    .frame(width:540,height:CGFloat(height)).environment(\.palette,palette).environment(\.colorScheme,dark ? .dark : .light)
                let host = NSHostingView(rootView:content); host.frame = NSRect(x:0,y:0,width:540,height:height)
                let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
                window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua); window.contentView = host; host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds)); host.cacheDisplay(in:host.bounds,to:bitmap)
                let data = try #require(bitmap.representation(using:.png,properties:[:]))
                let filename = name + (dark ? "-dark.png" : "-light.png"); try data.write(to:root.appendingPathComponent(filename))
                manifest.append(["file":filename,"sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),"width":540,"height":height,"fake_calls":f.base.spy.calls,"request":f.model.request != nil,"correction":f.model.correction != nil])
                window.contentView = nil
            }
        }
        f.model.reload(); try capture("loading"); try await f.settle()
        try capture("waiting-consent",tab:"Очередь")
        f.model.prepare(try await f.job(doc.uuidString)); try await f.settle(); try capture("exact-context",height:2400)
        f.model.send(); try await f.settle(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle(); try capture("overview")
        let event = try #require(f.model.heads.first?.entry.event)
        f.model.inspect(event); try await f.settle(); try capture("provenance")
        f.model.open(try #require(f.model.inspected?.sources.first)); try await f.settle(); try capture("checked-source")
        f.model.back(); f.model.prepareCorrection(event,text:"Срок уточнён вручную",retract:false,earliest:f.base.day("2026-12-05"),latest:f.base.day("2026-12-05"),decision:nil)
        try await f.settle(); try capture("manual-preview")
        f.model.cancelAction(); try capture("cancelled"); try capture("history",tab:"История")
        let version = try #require(try await f.base.store.versions(for:doc).first), file = try await f.base.importer.fileURL(for:version)
        try Data("Синтетический источник изменён извне".utf8).write(to:file,options:.atomic)
        f.model.reload(); try await f.settle(); try capture("stale-source")
        try await f.base.store.setCloudPolicy(.localOnly,for:p); await f.worker.changed(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle(); try capture("denied",tab:"Очередь")
        try await f.open(empty); try capture("empty")
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("render-manifest.json"))
        #expect(manifest.count == 24 && f.base.spy.calls == 1)
        await f.cleanup()
    }
}

@MainActor private final class PanelCleanupWitness {
    weak var fixture: MemoryPanelFixture?
    weak var base: UpdateFixture?
    weak var model: ProjectMemoryPanelModel?
    weak var worker: ProjectMemoryQueueWorker?
    weak var store: ProjectStore?
    // Keeping the spy alive makes callback release observable independently of
    // fixture deinit. It must not retain a store after scoped cleanup.
    var spy: MemoryTransportSpy?
    var root: URL?
}
private enum PanelFixtureBodyFailure: Error, Equatable { case intentional }

@MainActor extension ProjectMemoryPanelTests {
    private func leaveActivePanelWithoutSuccessCleanup(cancel: Bool, witness: PanelCleanupWitness) async throws {
        let f = try MemoryPanelFixture(), project = try await f.base.project(policy: .askEveryTime)
        let document = try await f.base.document(owners: [project])
        witness.fixture = f; witness.base = f.base; witness.model = f.model
        witness.worker = f.worker; witness.store = f.base.store
        witness.spy = f.base.spy; witness.root = f.base.root
        let entered = IndexGate(), release = IndexGate(), original = f.base.spy.afterAttempt
        f.releaseOnFinish(release)
        // Deliberate fixture -> spy -> callback -> fixture cycle, with a real
        // caller-owned approval suspended inside the noncooperative adapter.
        f.base.spy.afterAttempt = { [f] attempt in
            try await original?(attempt); await entered.signal(); await release.wait()
            #expect(f.base.spy.calls == 1)
        }
        await f.worker.start(); await f.worker.waitUntilIdle()
        f.model.start(); try await f.open(project)
        f.model.prepare(try await f.job(document.uuidString)); try await f.settle()
        f.model.send(); await entered.wait()
        if cancel {
            withUnsafeCurrentTask { $0?.cancel() }
            try Task.checkCancellation()
        }
        throw PanelFixtureBodyFailure.intentional
    }

    @Test(arguments: [false, true])
    func scopedPanelCleanupReleasesCallbackCycleAfterThrowOrCancellation(cancel: Bool) async throws {
        let scope = SQLiteFixtureScope(test: "panel-cleanup-cancel-\(cancel)")
        let witness = PanelCleanupWitness()
        try await SQLiteFixtureScope.$current.withValue(scope) {
            try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
                // Cancellation belongs to the child body; teardown runs in the
                // live parent, so its native-close wait cannot be cancelled.
                let body = Task { @MainActor in
                    try await leaveActivePanelWithoutSuccessCleanup(cancel: cancel, witness: witness)
                }
                let outcome = await body.result
                if cancel {
                    #expect(body.isCancelled)
                    if case .failure(let error) = outcome { #expect(error is CancellationError) }
                    else { Issue.record("Cancelled panel body unexpectedly succeeded") }
                } else {
                    #expect(throws: PanelFixtureBodyFailure.intentional) { try outcome.get() }
                }
                let root = try #require(witness.root)
                #expect(witness.fixture != nil && witness.spy?.afterAttempt != nil)
                #expect(FileManager.default.fileExists(atPath: root.path))
                scope.note("panel-body-error-observed")
                try await scope.finish()
                #expect(witness.fixture == nil && witness.base == nil && witness.model == nil)
                #expect(witness.worker == nil && witness.store == nil)
                #expect(witness.spy?.afterAttempt == nil && witness.spy?.beforeAttempt == nil && witness.spy?.calls == 1)
                #expect(!FileManager.default.fileExists(atPath: root.path))
                let trace = scope.trace
                let closes = trace.filter { $0["stage"] == "closed" }
                #expect(!closes.isEmpty && closes.allSatisfy { $0["result"] == "0" })
                #expect(!trace.contains { $0["stage"] == "sqlite-failure" || $0["stage"] == "teardown-timeout" })
                let close = try #require(trace.lastIndex { $0["stage"] == "closed" })
                let removed = try #require(trace.firstIndex { $0["stage"] == "root-removed" })
                #expect(close < removed)
            }
        }
    }
}

@MainActor extension ProjectMemoryPanelTests {
    @Test func actualQueuePartialFailureRetryInsufficientAndNativeStateRenders() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(policy:.askEveryTime)
        let folder = f.base.root.appendingPathComponent("meetings/long")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let segments = (0..<25).map { ["start":Double($0*20),"end":Double($0*20+10),"text":"Релиз LONG_\($0)"] as [String:Any] }
        try JSONSerialization.data(withJSONObject:["meetingId":"long","segments":segments]).write(to:folder.appendingPathComponent("transcript.json"))
        _ = try await MeetingEmbeddingSnapshotReader(root:f.base.root.appendingPathComponent("meetings")).synchronize(meetingID:"long",store:f.base.store)
        try await f.base.store.assignMeeting("long",to:[p]); try await f.base.finishIndex()
        await f.worker.start(); await f.worker.waitUntilIdle(); f.model.start(); try await f.open(p)
        let library = ProjectLibrary(store:f.base.store); await library.reload()
        var manifest:[[String:Any]] = []
        func capture(_ name:String) throws {
            guard let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_MEMORY_PANEL"], !output.isEmpty else { return }
            let root = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            for dark in [false,true] {
                let content = ProjectMemoryPanel(model:f.model,initialTab:"Очередь").environmentObject(library).frame(width:420,height:1200)
                    .environment(\.palette,dark ? .dark : .light).environment(\.colorScheme,dark ? .dark : .light)
                let host = NSHostingView(rootView:content); host.frame = NSRect(x:0,y:0,width:420,height:1200)
                let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
                window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua); window.contentView = host; host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds)); host.cacheDisplay(in:host.bounds,to:bitmap)
                let data = try #require(bitmap.representation(using:.png,properties:[:])), file = name + (dark ? "-dark.png" : "-light.png")
                try data.write(to:root.appendingPathComponent(file)); window.contentView = nil
                manifest.append(["file":file,"sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),"fake_calls":f.base.spy.calls])
            }
        }
        f.model.prepare(try await f.job("long")); try await f.settle(); f.model.send(); try await f.settle(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        #expect(try await f.job("long").completedChunks == 12 && f.base.spy.calls == 1)
        try capture("partial-consent")
        let entered = IndexGate(), release = IndexGate(), original = f.base.spy.afterAttempt
        f.releaseOnFinish(release)
        f.base.spy.afterAttempt = { i in try await original?(i); await entered.signal(); await release.wait() }
        f.base.spy.failure = URLError(.notConnectedToInternet)
        f.model.prepare(try await f.job("long")); try await f.settle(); f.model.send(); await entered.wait()
        for _ in 0..<20 { if f.model.queue.jobs.contains(where:{ $0.state == .running }) { break }; await Task.yield() }
        try capture("working")
        await release.signal(); try await f.settle(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        #expect(try await f.job("long").state == .failed && f.base.spy.calls == 2)
        try capture("network-error")
        f.base.spy.failure = nil
        f.base.spy.afterAttempt = { _ in f.base.spy.reply = try f.base.response([],insufficient:true) }
        f.model.retry(try await f.job("long")); try await f.settle(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        for _ in 0..<2 {
            f.model.prepare(try await f.job("long")); try await f.settle(); f.model.send(); try await f.settle(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        }
        #expect(try await f.job("long").state == .insufficient && f.base.spy.calls == 4)
        try capture("insufficient")
        try await f.base.meeting("cancel",text:"Релиз CANCEL",owners:[p]); await f.worker.changed(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        f.model.cancel(try await f.job("cancel")); try await f.settle()
        #expect(try await f.job("cancel").state == .cancelled)
        try capture("cancelled-job")
        _ = try await f.base.document("Релиз ждёт индекса",owners:[p],ready:false)
        await f.worker.changed(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle(); try capture("waiting-index")
        try await f.base.meeting("cap",text:"Релиз 2026-11-26",owners:[p]); let h = try await f.base.hit("cap",project:p)
        for i in 0..<8 {
            let lease = try await f.base.history.begin(projectID:p,producerKey:"cap-\(i)",hits:[h])
            _ = try await f.base.history.publish((0..<32).map { _ in .init(statement:.init(subject:"release:sever",kind:.deadline,conditions:["environment":"production"],text:"Релиз 2026-11-26",deadline:.init(earliest:f.base.day("2026-11-26"),latest:f.base.day("2026-11-26"))),evidenceChunkIDs:[h.id]) },lease:lease)
        }
        f.base.spy.afterAttempt = original
        await f.worker.changed(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        f.model.prepare(try await f.job("cap")); try await f.settle(); f.model.send(); try await f.settle(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        #expect(try await f.job("cap").state == .limited && f.base.spy.calls == 5)
        try capture("limited")
        if let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_MEMORY_PANEL"], !output.isEmpty {
            try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output).appendingPathComponent("queue-render-manifest.json"))
            #expect(manifest.count == 14)
        }
        await f.cleanup()
    }
}

@MainActor extension ProjectMemoryPanelTests {
    @Test func actualPDFPageTwoAndConflictingClaimsRenderThenOldVersionIsRejected() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project()
        let pdfFile = f.base.root.appendingPathComponent("План.pdf"), data = NSMutableData()
        var rect = CGRect(x:0,y:0,width:600,height:800)
        let consumer = try #require(CGDataConsumer(data:data))
        let context = try #require(CGContext(consumer:consumer,mediaBox:&rect,nil))
        for text in ["Обложка проекта", "Релиз 2026-12-05. Я сделал проверку."] {
            context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
            (text as NSString).draw(at:CGPoint(x:30,y:650),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF(); try (data as Data).write(to:pdfFile)
        let doc = try await f.base.importer.importFile(id:UUID(),url:pdfFile,projectIDs:[p]) { _ in }.documentID
        try await f.base.meeting("first",text:"Релиз 2026-11-26",owners:[p]); try await f.base.finishIndex()
        let a = try await f.base.hit("first",project:p)
        let b = try #require(try await f.base.search.search("релиз",scope:.project(p)).hits.first { $0.source.key.externalID == doc.uuidString && $0.chunk.location.page == 2 })
        let one = try await f.base.history.begin(projectID:p,producerKey:"pdf-old",hits:[a])
        let original = try #require(try await f.base.history.publish([.init(statement:.init(subject:"release",kind:.deadline,conditions:[:],text:"Релиз 26 ноября",deadline:.init(earliest:f.base.day("2026-11-26"),latest:f.base.day("2026-11-26"))),evidenceChunkIDs:[a.id])],lease:one).eventIDs.first)
        let two = try await f.base.history.begin(projectID:p,producerKey:"pdf-new",hits:[b],parentEventIDs:[original])
        let ids = try await f.base.history.publish([
            .init(statement:.init(subject:"release",kind:.deadline,conditions:[:],text:"В плане указан новый срок: 5 декабря",deadline:.init(earliest:f.base.day("2026-12-05"),latest:f.base.day("2026-12-05"))),evidenceChunkIDs:[b.id]),
            .init(statement:.init(subject:"check",kind:.completionClaim,conditions:[:],text:"Участник сообщил о выполнении проверки"),evidenceChunkIDs:[b.id]),
            .init(statement:.init(subject:"owner",kind:.openQuestion,conditions:[:],text:"Кто подтвердит готовность перед релизом?"),evidenceChunkIDs:[b.id])
        ],lease:two).eventIDs
        try await f.open(p)
        #expect(f.model.heads.contains { $0.head?.conflictingEventIDs == [original] && !$0.usable })
        let library = ProjectLibrary(store:f.base.store); await library.reload()
        var manifest:[[String:Any]] = []
        func capture(_ name:String) async throws {
            guard let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_MEMORY_PANEL"], !output.isEmpty else { return }
            let root = URL(fileURLWithPath:output)
            for dark in [false,true] {
                let h = name == "conflicts-claims" ? 1700 : 1100
                let content = ProjectMemoryPanel(model:f.model).environmentObject(library).frame(width:540,height:CGFloat(h))
                    .environment(\.palette,dark ? .dark : .light).environment(\.colorScheme,dark ? .dark : .light)
                let host = NSHostingView(rootView:content); host.frame = NSRect(x:0,y:0,width:540,height:h)
                let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
                window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua); window.contentView = host
                host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(100)); host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds)); host.cacheDisplay(in:host.bounds,to:bitmap)
                let data = try #require(bitmap.representation(using:.png,properties:[:])), file = name + (dark ? "-dark.png" : "-light.png")
                try data.write(to:root.appendingPathComponent(file)); window.contentView = nil
                manifest.append(["file":file,"sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),"fake_calls":f.base.spy.calls])
            }
        }
        try await capture("conflicts-claims")
        let event = try #require(f.model.heads.first { $0.id == ids.first }?.entry.event)
        f.model.inspect(event); try await f.settle()
        let source = try #require(f.model.inspected?.sources.first { $0.chunk.location.page == 2 })
        f.model.open(source); try await f.settle()
        #expect(f.model.destination?.pdf == (data as Data) && f.model.destination?.hit.chunk.location.page == 2)
        try await capture("pdf-page2")
        f.model.back(); _ = try await f.base.document("Новая версия",owners:[p],target:doc)
        f.model.open(source); try await f.settle(); #expect(f.model.destination == nil && f.model.stale && f.base.spy.calls == 0)
        if let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_MEMORY_PANEL"], !output.isEmpty {
            try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output).appendingPathComponent("pdf-render-manifest.json"))
        }
        await f.cleanup()
    }
}

@MainActor extension ProjectMemoryPanelTests {
    @Test func derivedPreviewIncludesAllOwnersButOnlySelectedTextsAndCannotOverridePrivateAncestor() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(policy:.askEveryTime), q = try await f.base.project("Общий владелец",policy:.localOnly)
        let a = try await f.base.document("Релиз HIDDEN_RAW 2026-11-26",owners:[p,q]), h = try await f.base.hit(a.uuidString,project:p)
        _ = try await f.base.seed(project:p,hit:h,text:"DERIVED_SELECTED 2026-11-26")
        let b = try await f.base.document("Релиз VISIBLE_RAW 2026-11-26",owners:[p])
        await f.worker.changed()
        for job in try await f.base.store.memoryQueueSnapshot().jobs where job.source.externalID == a.uuidString { try await f.base.store.cancelMemoryQueue(job.sequence) }
        await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
        f.model.prepare(try await f.job(b.uuidString)); try await f.settle()
        #expect(f.model.request?.denied == true && !f.model.canSend)
        f.model.send(); #expect(f.base.spy.calls == 0)
        try await f.base.store.setCloudPolicy(.askEveryTime,for:q); await f.worker.changed(); await f.worker.waitUntilIdle(); f.model.reload(); try await f.settle()
        f.model.prepare(try await f.job(b.uuidString)); try await f.settle()
        let request = try #require(f.model.request)
        #expect(request.parents.count == 1 && request.ownerProjectIDs == [p,q] && request.consumedSources.count == 2)
        #expect(request.payload.contains("DERIVED_SELECTED") && request.payload.contains("VISIBLE_RAW") && !request.payload.contains("HIDDEN_RAW"))
        if let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_MEMORY_PANEL"], !output.isEmpty {
            let library = ProjectLibrary(store:f.base.store); await library.reload()
            var manifest:[[String:Any]] = []
            for dark in [false,true] {
                let content = ProjectMemoryPanel(model:f.model).environmentObject(library).frame(width:460,height:2300)
                    .environment(\.palette,dark ? .dark : .light).environment(\.colorScheme,dark ? .dark : .light)
                let host = NSHostingView(rootView:content); host.frame = NSRect(x:0,y:0,width:460,height:2300)
                let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
                window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua); window.contentView = host; host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds)); host.cacheDisplay(in:host.bounds,to:bitmap)
                let data = try #require(bitmap.representation(using:.png,properties:[:])), file = "derived-context" + (dark ? "-dark.png" : "-light.png")
                try data.write(to:URL(fileURLWithPath:output).appendingPathComponent(file)); window.contentView = nil
                manifest.append(["file":file,"sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),"fake_calls":0,"owners":2,"raw":1,"derived":1])
            }
            try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output).appendingPathComponent("derived-render-manifest.json"))
        }
        f.model.send(); try await f.settle(); await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 1 && f.base.spy.payload == request.payload)
        #expect(try await f.job(b.uuidString).completeCoverage)
        await f.cleanup()
    }
}

@MainActor extension ProjectMemoryPanelTests {
    @Test func closingOldPanelDoesNotDiscardAnotherPanelsExactPreview() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(policy:.askEveryTime), q = try await f.base.project("Другой",policy:.askEveryTime)
        let a = try await f.base.document(owners:[p]), b = try await f.base.document("Релиз 2026-12-05",owners:[q])
        await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
        f.model.prepare(try await f.job(a.uuidString)); try await f.settle(); let old = try #require(f.model.request)
        let other = ProjectMemoryPanelModel(store:f.base.store,worker:f.worker,meetingsRoot:f.base.root.appendingPathComponent("meetings"),documentsRoot:f.base.root.appendingPathComponent("copies"),projectID:q)
        f.track(other)
        other.reload(); try await f.settle(other)
        other.prepare(try #require(other.queue.jobs.first { $0.source.externalID == b.uuidString })); try await f.settle(other)
        let current = try #require(other.request)
        f.model.close(); for _ in 0..<5 { await Task.yield() }
        #expect(old.id != current.id && f.worker.hasPreview(current.id) && other.canSend)
        other.send(); try await f.settle(other); await f.worker.waitUntilIdle()
        #expect(f.base.spy.calls == 1 && f.base.spy.payload == current.payload)
        #expect(try await f.base.store.memoryQueueSnapshot(projectID:p).jobs.first?.completedChunks == 0)
        other.close(); await f.cleanup()
    }

    @Test func meetingAssignmentAndConfigurationInvalidateScopeAndPendingConsent() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(policy:.askEveryTime), q = try await f.base.project("Другой",policy:.askEveryTime)
        try await f.base.meeting("current",text:"Релиз 2026-11-26",owners:[p])
        let center = NotificationCenter(), configuration = PassthroughSubject<(Bool,String),Never>()
        let panel = ProjectMemoryPanelModel(store:f.base.store,worker:f.worker,meetingsRoot:f.base.root.appendingPathComponent("meetings"),documentsRoot:f.base.root.appendingPathComponent("copies"),meetingID:"current",center:center,configuration:configuration.eraseToAnyPublisher())
        f.track(panel)
        await f.worker.start(); await f.worker.waitUntilIdle(); panel.start(); try await f.settle(panel)
        #expect(panel.projectID == p && panel.allowedProjects == [p])
        try await f.base.store.assignMeeting("current",to:[q]); await f.worker.changed(); await f.worker.waitUntilIdle()
        KnowledgeIndexEvents.post(.projects,center:center)
        let deadline = ContinuousClock.now + .seconds(8)
        while panel.projectID != q || panel.loading {
            guard ContinuousClock.now < deadline else { throw MemoryQueueError.busy }; try await Task.sleep(for:.milliseconds(5))
        }
        #expect(panel.allowedProjects == [q] && panel.queue.jobs.allSatisfy { $0.projectID == q })
        panel.prepare(try #require(panel.queue.jobs.first)); try await f.settle(panel); let request = try #require(panel.request)
        configuration.send((false,"Новая модель")); try await f.settle(panel); panel.send()
        #expect(!panel.enabled && panel.provider == "Новая модель" && panel.request == nil && f.base.spy.calls == 0)
        for _ in 0..<5 { await Task.yield() }
        #expect(!f.worker.hasPreview(request.id))
        panel.close(); await f.cleanup()
    }
}

@MainActor extension ProjectMemoryPanelTests {
    @Test func closingOldSenderCannotCancelNewerRetryOfSameSource() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(policy:.askEveryTime)
        let doc = try await f.base.document(owners:[p]), entered = IndexGate(), release = IndexGate(), original = f.base.spy.afterAttempt
        f.releaseOnFinish(release)
        f.base.spy.afterAttempt = { i in try await original?(i); if f.base.spy.calls == 1 { await entered.signal(); await release.wait() } }
        await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
        f.model.prepare(try await f.job(doc.uuidString)); try await f.settle(); f.model.send(); await entered.wait()
        let old = try await f.job(doc.uuidString)
        await f.worker.cancel(old.sequence); await f.worker.retry(old.sequence)
        let newer = try await f.job(doc.uuidString)
        f.model.close()
        for _ in 0..<10 { await Task.yield() }
        let stillNewer = try await f.job(doc.uuidString)
        #expect(stillNewer.generation == newer.generation && stillNewer.state != .cancelled)
        await release.signal()
        // Explicit approval is owned by its caller, not the background drain
        // handle. Observe the durable resumed state after the old caller joins.
        let deadline = ContinuousClock.now + .seconds(8)
        while try await f.job(doc.uuidString).state != .needsConsent {
            guard ContinuousClock.now < deadline else { throw MemoryQueueError.busy }
            try await Task.sleep(for:.milliseconds(5))
        }
        #expect(f.base.spy.calls == 1)
        #expect(try await f.base.history.history(projectID:p).entries.isEmpty)
        await f.cleanup()
    }
}

@MainActor extension ProjectMemoryPanelTests {
    @Test func manualDateOnlyControlsPersistCanonicalCivilDaysWithoutImportDateSubstitution() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project()
        _ = try await f.base.document(owners:[p]); await f.worker.start(); await f.worker.waitUntilIdle(); await f.worker.stop(); try await f.open(p)
        let event = try #require(f.model.heads.first?.entry.event)
        f.model.prepareCorrection(event,text:"Срок подтверждён пользователем",retract:false,
            earliest:f.base.day("2026-12-05").addingTimeInterval(20*3600),latest:f.base.day("2026-12-05").addingTimeInterval(22*3600),decision:f.base.day("2026-11-20").addingTimeInterval(17*3600))
        try await f.settle()
        #expect(f.model.correction?.draft.statement.deadline?.earliest == f.base.day("2026-12-05"))
        #expect(f.model.correction?.draft.decisionDate == f.base.day("2026-11-20"))
        f.model.publishCorrection(); try await f.settle()
        let stored = try #require(try await f.base.history.history(projectID:p).entries.first?.event)
        #expect(stored.origin == .manual && stored.decisionDate == f.base.day("2026-11-20"))
        #expect(stored.statement.deadline?.latest == f.base.day("2026-12-05") && stored.sources.allSatisfy { $0.sourceDate == nil })
        #expect(f.base.spy.calls == 1)
        await f.cleanup()
    }
}
