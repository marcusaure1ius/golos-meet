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
        let worker = worker, model = model
        SQLiteFixtureScope.current?.onFinish { @MainActor [weak base, weak worker, weak model] in
            model?.close(); base?.cleanup()
            await worker?.stop()
            SQLiteFixtureScope.current?.note("panel-scope-stop-requested")
        }
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
    }
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

    @Test func oldVersionSourceCannotReopenAsCurrentAndProjectChangeDropsOldInspection() async throws {
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

    @Test func inspectionClosesOnFilterOrProjectChangeAndFileChangeMarksSourcesUnconfirmed() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(), q = try await f.base.project("Пустой")
        let doc = try await f.base.document(owners:[p])
        await f.worker.start(); await f.worker.waitUntilIdle(); await f.worker.stop()
        let baseline = f.base.spy.calls
        try await f.open(p)
        let event = try #require(f.model.heads.first?.entry.event)
        f.model.inspect(event); try await f.settle()
        #expect(f.model.inspected?.rootEventID == event.id)
        f.model.filter = "новый фильтр"; try await f.settle()
        #expect(f.model.inspected == nil && f.base.spy.calls == baseline)
        f.model.filter = ""; try await f.settle()
        f.model.inspect(event); try await f.settle()
        try await f.open(q)
        #expect(f.model.heads.isEmpty && f.model.inspected == nil && f.model.destination == nil)
        try await f.open(p)
        #expect(f.model.heads.first?.usable == true)
        let version = try #require(try await f.base.store.versions(for:doc).first), file = try await f.base.importer.fileURL(for:version)
        try Data("Синтетический источник изменён извне".utf8).write(to:file,options:.atomic)
        f.model.reload(); try await f.settle()
        #expect(f.model.heads.first?.ancestry == .unconfirmed && f.base.spy.calls == baseline)
        await f.cleanup()
    }

    @Test func meetingScopeAutoSelectsProjectAndFollowsAssignmentChange() async throws {
        let f = try MemoryPanelFixture(), p = try await f.base.project(), q = try await f.base.project("Другой")
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
        configuration.send((false,"Новая модель")); try await f.settle(panel)
        #expect(!panel.enabled && panel.provider == "Новая модель")
        panel.close(); await f.cleanup()
    }

    @Test func renderActualNativePanelStatesWhenExplicitlyRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_MEMORY_PANEL"], !output.isEmpty else { return }
        let root = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let f = try MemoryPanelFixture(), p = try await f.base.project(), empty = try await f.base.project("Пустой")
        let library = ProjectLibrary(store:f.base.store); await library.reload()
        _ = try await f.base.document(owners:[p]); await f.worker.start(); await f.worker.waitUntilIdle(); try await f.open(p)
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
                manifest.append(["file":filename,"sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),"width":540,"height":height,"fake_calls":f.base.spy.calls])
                window.contentView = nil
            }
        }
        f.model.reload(); try capture("loading"); try await f.settle()
        try capture("overview")
        try capture("queue",tab:"Очередь")
        let event = try #require(f.model.heads.first?.entry.event)
        f.model.inspect(event); try await f.settle(); try capture("provenance")
        f.model.open(try #require(f.model.inspected?.sources.first)); try await f.settle(); try capture("checked-source")
        f.model.back(); f.model.dismissDetails(); try await f.settle()
        try capture("history",tab:"История")
        try await f.open(empty); try capture("empty")
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("render-manifest.json"))
        #expect(manifest.count == 14 && f.base.spy.calls == 1)
        await f.cleanup()
    }
}
