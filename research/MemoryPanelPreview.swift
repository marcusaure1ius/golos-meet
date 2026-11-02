import SwiftUI
import AppKit
import Combine

// Isolated native host: explicit temporary paths, no real app/Keychain/client.
enum AppPaths {
    static let appSupport: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey:"SyntheticRoot") as! String
        precondition(raw.hasPrefix(NSTemporaryDirectory()) || raw.hasPrefix("/private/var/folders/"))
        return URL(fileURLWithPath:raw)
    }()
    static var meetingsRoot: URL { appSupport.appendingPathComponent("meetings") }
}
actor PanelPreviewGate {
    var held = false
    var waiters: [CheckedContinuation<Void,Never>] = []
    func arm() { held = true }
    func wait() async { if held { await withCheckedContinuation { waiters.append($0) } } }
    func release() { held = false; waiters.forEach { $0.resume() }; waiters = [] }
}
@MainActor final class PanelPreviewClient: ChatCompleter,ObservableObject {
    @Published var calls = 0
    @Published var mode = "Факты"
    let gate = PanelPreviewGate()
    nonisolated func complete(model:String,messages:[ChatMessage],responseFormat:ResponseFormat?) async throws -> String { try await send(messages) }
    private func send(_ messages:[ChatMessage]) async throws -> String {
        calls += 1; let mode = mode, payload = messages.last!.content
        trace(["action":"fake_transport","calls":calls,"mode":mode,"payload":payload])
        await gate.wait()
        if mode == "Нет ключа" { throw LLMError.noAPIKey }
        if mode == "Нет сети" { throw URLError(.notConnectedToInternet) }
        if mode == "Неверный ответ" { return "invalid JSON" }
        let object = try JSONSerialization.jsonObject(with:Data(payload.utf8)) as! [String:Any]
        let fragments = object["fragments"] as! [[String:Any]]
        let facts: [[String:Any]] = fragments.map {
            let text = $0["text"] as! String
            return ["subject":"raw:"+MemoryEncoding.hash(text),"kind":"agreement","conditions":[:],"text":text,"action":"assertion","deadline":NSNull(),"decisionDate":NSNull(),"evidence":[["source":$0["label"] as! String,"quote":String(text.prefix(1000))]],"links":[]]
        }
        return String(decoding:try JSONSerialization.data(withJSONObject:["insufficientEvidence":mode == "Недостаточно","facts":mode == "Недостаточно" ? [] : facts]),as:UTF8.self)
    }
    func trace(_ value:[String:Any]) {
        let file = AppPaths.appSupport.appendingPathComponent("ui-events.jsonl")
        guard var data = try? JSONSerialization.data(withJSONObject:value) else { return }; data.append(10)
        if !FileManager.default.fileExists(atPath:file.path) { FileManager.default.createFile(atPath:file.path,contents:nil) }
        guard let handle = try? FileHandle(forWritingTo:file) else { return }; defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf:data)
    }
}
@MainActor final class PanelPreviewState: ObservableObject {
    let store: ProjectStore
    let projects: ProjectLibrary
    let worker: ProjectMemoryQueueWorker
    let model: ProjectMemoryPanelModel
    let client = PanelPreviewClient()
    @Published var notice = "Создаём synthetic SQLite…"
    @Published var dark = false
    private var project: UUID?
    private var counter = 0
    init() {
        let root = AppPaths.appSupport
        let store = ProjectStore(url:root.appendingPathComponent("knowledge.sqlite")); self.store = store
        projects = .init(store:store)
        let worker = ProjectMemoryQueueWorker(store:store,meetingsRoot:AppPaths.meetingsRoot,documentsRoot:root.appendingPathComponent("copies"),client:client,model:"fake-only"); self.worker = worker
        model = .init(store:store,worker:worker,meetingsRoot:AppPaths.meetingsRoot,documentsRoot:root.appendingPathComponent("copies"),provider:"Fake · без сети",center:.default)
        Task {
            do {
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                let p = try await store.createProject(name:"Север"), q = try await store.createProject(name:"Приватный"), _ = try await store.createProject(name:"Без материалов")
                project = p.id; try await store.setCloudPolicy(.askEveryTime,for:p.id); try await store.setCloudPolicy(.localOnly,for:q.id)
                try await meeting("current","Релиз 2026-11-26. Проверим готовность нагрузки.",count:1,owner:p.id)
                try await meeting("private","Приватная договорённость",count:1,owner:q.id)
                let pdf = root.appendingPathComponent("План релиза.pdf")
                try Self.pdf(["Обложка проекта Север", "Релиз 2026-12-05. Я сделал проверку."]).write(to:pdf)
                _ = try await DocumentImporter(store:store,root:root.appendingPathComponent("copies")).importFile(id:UUID(),url:pdf,projectIDs:[p.id]) { _ in }
                try await ready()
                let search = KnowledgeSearchService(store:store,meetingsRoot:AppPaths.meetingsRoot,documentsRoot:root.appendingPathComponent("copies"),queryEmbedding:{ _ in throw LocalIndexingError.missingModel })
                let a = try await search.search("релиз",scope:.project(p.id)).hits.first { $0.source.key.kind == .meeting }!
                let b = try await search.search("релиз",scope:.project(p.id)).hits.first { $0.chunk.location.page == 2 }!
                let history = ProjectMemoryHistoryService(store:store,meetingsRoot:AppPaths.meetingsRoot,documentsRoot:root.appendingPathComponent("copies"))
                let day: (String)->Date = { ISO8601DateFormatter().date(from:$0+"T00:00:00Z")! }
                let first = try await history.begin(projectID:p.id,producerKey:"seed-1",hits:[a])
                let old = try await history.publish([.init(statement:.init(subject:"release",kind:.deadline,conditions:[:],text:"Релиз назначен на 26 ноября",deadline:.init(earliest:day("2026-11-26"),latest:day("2026-11-26"))),evidenceChunkIDs:[a.id])],lease:first).eventIDs[0]
                let second = try await history.begin(projectID:p.id,producerKey:"seed-2",hits:[b],parentEventIDs:[old])
                _ = try await history.publish([
                    .init(statement:.init(subject:"release",kind:.deadline,conditions:[:],text:"В новом плане релиз перенесён на 5 декабря",deadline:.init(earliest:day("2026-12-05"),latest:day("2026-12-05"))),evidenceChunkIDs:[b.id]),
                    .init(statement:.init(subject:"check",kind:.completionClaim,conditions:[:],text:"Участник сообщил о выполнении проверки"),evidenceChunkIDs:[b.id]),
                    .init(statement:.init(subject:"question",kind:.openQuestion,conditions:[:],text:"Кто подтвердит готовность нагрузки перед релизом?"),evidenceChunkIDs:[b.id])
                ],lease:second)
                await projects.reload(); await worker.start(); await worker.waitUntilIdle(); model.projectID = p.id
                notice = "Synthetic host · temp SQLite · реальные service/worker/UI · fake LLM · без записи и сети"
            } catch { notice = "Ошибка synthetic setup: \(error)" }
        }
    }
    func meeting(_ id:String,_ text:String,count:Int,owner:UUID) async throws {
        let folder = AppPaths.meetingsRoot.appendingPathComponent(id)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let segments = (0..<count).map { ["start":42.5 + Double($0*20),"end":55 + Double($0*20),"text":text + (count > 1 ? " Часть \($0+1)." : "")] as [String:Any] }
        try JSONSerialization.data(withJSONObject:["meetingId":id,"segments":segments]).write(to:folder.appendingPathComponent("transcript.json"),options:.atomic)
        _ = try await MeetingEmbeddingSnapshotReader(root:AppPaths.meetingsRoot).synchronize(meetingID:id,store:store)
        try await store.assignMeeting(id,to:[owner])
    }
    func ready() async throws {
        let m = EmbeddingIndexModel(id:"synthetic-preview37",dimensions:2)
        if try await store.knowledgeSearchModel().model != m { try await store.activateEmbeddingModel(m) }
        while let lease = try await store.claimEmbeddingJob() {
            let vectors = try lease.snapshot.chunks.map { IndexedChunkVectors(chunkID:$0.id,bodyTokenCount:1,windows:[.init(tokenStart:0,tokenCount:1,vector:try KnowledgeVector(modelID:m.id,values:[1,0]))]) }
            let published = try await store.publishEmbeddingVectors(vectors,lease:lease); precondition(published)
        }
    }
    func add(_ count:Int) {
        Task {
            do { guard let project else { return }; counter += 1; try await meeting("new-\(counter)","Новый релиз и проверка \(counter)",count:count,owner:project); try await ready(); await worker.changed(); model.reload() }
            catch { notice = "Synthetic add: \(error)" }
        }
    }
    func mutate() {
        Task {
            do {
                guard let project else { return }
                try await meeting("current","Изменённый источник: релиз 2026-12-12",count:1,owner:project); try await ready()
                KnowledgeIndexEvents.post(.meeting("current")); await worker.changed(); model.reload()
            } catch { notice = "Synthetic mutation: \(error)" }
        }
    }
    static func pdf(_ pages:[String]) -> Data {
        let data = NSMutableData(); var bounds = CGRect(x:0,y:0,width:600,height:800)
        let context = CGContext(consumer:CGDataConsumer(data:data)!,mediaBox:&bounds,nil)!
        for text in pages {
            context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
            (text as NSString).draw(at:CGPoint(x:35,y:680),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
}
struct PanelPreviewRoot: View {
    @State private var showingMemory = false
    @ObservedObject var state: PanelPreviewState
    @ObservedObject var model: ProjectMemoryPanelModel
    @ObservedObject var client: PanelPreviewClient
    var body: some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:8) {
                Text(state.notice).font(.system(size:12))
                HStack {
                    Picker("Fake LLM",selection:$client.mode) { ForEach(["Факты","Недостаточно","Нет ключа","Нет сети","Неверный ответ"],id:\.self) { Text($0) } }.frame(width:220)
                    Text("Fake вызовов: \(client.calls)")
                    Button("Удержать") { Task { await client.gate.arm() } }
                    Button("Отпустить") { Task { await client.gate.release() } }
                    Toggle("Тёмная",isOn:$state.dark).toggleStyle(.switch).controlSize(.small)
                }
                HStack {
                    Button("Новая встреча") { state.add(1) }
                    Button("25 фрагментов") { state.add(25) }
                    Button("Изменить источник") { state.mutate() }
                    Button("Обновить") { model.reload() }
                }
            }.padding(12)
            Divider()
            HStack(spacing:0) {
                VStack(alignment:.leading,spacing:14) {
                    Text("Текущая встреча").font(.title2)
                    Text("Синтетическая расшифровка").font(.caption)
                    ProjectMemoryOpenButton { showingMemory.toggle() }
                    Text("00:42 · Участник\nРелиз 2026-11-26. Проверим готовность нагрузки.")
                    Spacer()
                    Text("Захват и ASR отсутствуют в этом host.").font(.caption)
                }.padding(24).frame(width:290)
            }
        }.projectMemoryInspector(isPresented:$showingMemory) {
            ProjectMemoryPanel(model:model).environmentObject(state.projects)
        }.task { model.start() }.onDisappear { model.close() }
            .frame(minWidth:920,minHeight:740)
            .environment(\.palette,Palette.of(state.dark ? .dark : .light)).preferredColorScheme(state.dark ? .dark : .light)
            .onChange(of:model.request?.id) { _,_ in client.trace(["action":"preview","present":model.request != nil,"calls":client.calls]) }
            .onChange(of:model.correction?.id) { _,_ in client.trace(["action":"correction-preview","present":model.correction != nil,"calls":client.calls]) }
            .onChange(of:model.destination?.id) { _,_ in client.trace(["action":"source","present":model.destination != nil,"calls":client.calls]) }
            .onChange(of:model.heads.count) { _,_ in client.trace(["action":"heads","count":model.heads.count,"calls":client.calls]) }
    }
}
struct PanelPreviewApp: App {
    @StateObject private var state = PanelPreviewState()
    var body: some Scene { WindowGroup("Golos Memory Panel Preview · Synthetic") { PanelPreviewRoot(state:state,model:state.model,client:state.client) }.defaultSize(width:1100,height:880) }
}
@main struct PanelPreviewEntry { static func main() { setenv("GOLOS_MEET_TEST_MODE","1",1); PanelPreviewApp.main() } }
