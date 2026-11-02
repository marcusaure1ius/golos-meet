import SwiftUI
import AppKit
import Combine
import CryptoKit
import SQLite3

// This alternate executable contains no normal app entry, client, credentials or audio.
enum AppPaths {
    static let appSupport: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SyntheticRoot") as! String
        let root = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        precondition(root.path.hasPrefix("/private/var/folders/") && root.path.hasPrefix(temporary.path + "/golos-memory-gate37-"))
        precondition(root.lastPathComponent == "library")
        return root
    }()
    static var meetingsRoot: URL { appSupport.appendingPathComponent("meetings") }
}

nonisolated enum GateFault: Error { case invalid(String) }
nonisolated enum GateClock {
    static var mono: Double { ProcessInfo.processInfo.systemUptime }
    static var utc: String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return formatter.string(from:Date())
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

nonisolated struct GateJob: Codable, Equatable, Sendable {
    let sequence, project, source, input, generation, cycle, state, cursor, total: String
    let attempt, selected, identity, model, contract, message: String
    let attemptIsNull, selectedIsNull: Bool
    func sameIdentity(as other: GateJob) -> Bool {
        sequence == other.sequence && project == other.project && source == other.source && input == other.input && cycle == other.cycle &&
        cursor == other.cursor && total == other.total && identity == other.identity && model == other.model && contract == other.contract
    }
}
nonisolated struct GateSQLSample: Codable, Sendable {
    let began, ended: Double
    let beganUTC, endedUTC, run: String
    let projects: [[String]], jobs: [GateJob], history: [[String]]
    let historyCount: Int
    var job: GateJob? { jobs.count == 1 ? jobs.first : nil }
}

// A separate read-only handle; each sample has one fresh read transaction, no busy wait.
actor GateSQLReader {
    private let url: URL
    private var db: OpaquePointer?
    init(url: URL) { self.url = url }
    private func rows(_ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw GateFault.invalid("SQL prepare code=\(sqlite3_errcode(db)) extended=\(sqlite3_extended_errcode(db))") }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, result.count < 4 else { throw GateFault.invalid("SQL step/bound code=\(code) extended=\(sqlite3_extended_errcode(db))") }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }
    func read() throws -> GateSQLSample {
        let began = GateClock.mono, beganUTC = GateClock.utc
        if db == nil {
            var opened: OpaquePointer?
            let code = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard code == SQLITE_OK else { if let opened { sqlite3_close(opened) }; throw GateFault.invalid("readonly open \(code)") }
            db = opened; sqlite3_busy_timeout(db, 0)
        }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw GateFault.invalid("readonly BEGIN code=\(sqlite3_errcode(db))") }
        do {
            let run = try rows("SELECT generation FROM memory_queue_runtime WHERE slot=1").first?.first ?? ""
            let projects = try rows("SELECT id,name,cloud_policy FROM projects ORDER BY id LIMIT 3")
            let raw = try rows("SELECT sequence,project_id,source_key,input,generation,cycle,state,cursor,total,COALESCE(attempt,''),COALESCE(selected_key,''),identity,generator_model,generator_contract,message,attempt IS NULL,selected_key IS NULL FROM memory_queue_work ORDER BY sequence LIMIT 3")
            let jobs = try raw.map { r -> GateJob in
                guard r.count == 17, ["0","1"].contains(r[15]), ["0","1"].contains(r[16]) else { throw GateFault.invalid("job shape") }
                return GateJob(sequence:r[0],project:r[1],source:r[2],input:r[3],generation:r[4],cycle:r[5],state:r[6],cursor:r[7],total:r[8],attempt:r[9],selected:r[10],identity:r[11],model:r[12],contract:r[13],message:r[14],attemptIsNull:r[15] == "1",selectedIsNull:r[16] == "1")
            }
            let count = Int(try rows("SELECT COUNT(*) FROM memory_events").first?.first ?? "") ?? -1
            let history = try rows("SELECT id,body FROM memory_events ORDER BY sequence LIMIT 2")
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw GateFault.invalid("readonly COMMIT code=\(sqlite3_errcode(db))") }
            return GateSQLSample(began:began,ended:GateClock.mono,beganUTC:beganUTC,endedUTC:GateClock.utc,run:run,projects:projects,jobs:jobs,history:history,historyCount:count)
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }
    func close() -> Int32 {
        guard let db else { return SQLITE_OK }
        let code = sqlite3_close(db)
        if code == SQLITE_OK { self.db = nil }
        return code
    }
}

nonisolated struct GateEvent: Encodable, Sendable {
    let session: UUID; let sequence: Int; let mono: Double; let utc, name: String
    let fields: [String:String]; let sample: GateSQLSample?
}
nonisolated struct GateLogReceipt: Codable, Sendable { let sequence: Int; let hash: String; let mono: Double }
@MainActor final class GateLog {
    let session = UUID()
    let folder: URL
    private let handle: FileHandle
    private(set) var sequence = 0
    private(set) var bytes = 0
    private(set) var broken: String?
    private var finalWritten = false
    private var logClosed = false
    private let limit = 2 * 1024 * 1024
    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("knowledge.sqlite").path) else { throw GateFault.invalid("Existing library: no reset/reuse") }
        try Data().write(to: folder.appendingPathComponent("diagnostic-events.jsonl"), options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: folder.appendingPathComponent("diagnostic-events.jsonl"))
        let metadata = ["session":session.uuidString,"createdUTC":GateClock.utc,"sourceCommit":Bundle.main.object(forInfoDictionaryKey:"SourceCommit") as? String ?? "missing","sourceManifestSHA256":Bundle.main.object(forInfoDictionaryKey:"SourceManifestSHA256") as? String ?? "missing","limits":"512events/2MiB; reads timestamped/non-atomic across samples"]
        try Data(try GateClock.json(metadata).utf8).write(to: folder.appendingPathComponent("session.json"), options: .withoutOverwriting)
    }
    @discardableResult func append(_ name: String, _ fields: [String:String] = [:], sample: GateSQLSample? = nil) throws -> GateLogReceipt {
        guard broken == nil, !finalWritten else { throw GateFault.invalid(broken ?? "log already final") }
        let at = GateClock.mono
        let event = GateEvent(session:session,sequence:sequence+1,mono:at,utc:GateClock.utc,name:name,fields:fields,sample:sample)
        var data = Data(try GateClock.json(event).utf8); data.append(10)
        guard sequence < 510, data.count <= 16384, bytes + data.count < limit - 20480 else {
            broken = "event/byte bound exceeded"
            let terminal = GateEvent(session:session,sequence:sequence+1,mono:at,utc:GateClock.utc,name:"diagnostic-overflow",fields:["error":broken!],sample:nil)
            var tail = Data(try GateClock.json(terminal).utf8); tail.append(10)
            try handle.write(contentsOf:tail); try handle.synchronize(); sequence += 1; bytes += tail.count
            throw GateFault.invalid(broken!)
        }
        do { try handle.write(contentsOf:data); try handle.synchronize() }
        catch { broken = "write/sync failure: \(error)"; throw error }
        sequence += 1; bytes += data.count
        return GateLogReceipt(sequence:sequence,hash:GateClock.hash(data),mono:at)
    }
    func finish(status: String, fields: [String:String]) throws {
        guard !finalWritten else { return }
        if status == "Passed", broken != nil { throw GateFault.invalid("broken log cannot pass") }
        let raw = try Data(contentsOf:folder.appendingPathComponent("diagnostic-events.jsonl"))
        let manifest = ["status":status,"session":session.uuidString,"events":String(sequence),"logBytes":String(bytes),"logSHA256":GateClock.hash(raw),"finishedUTC":GateClock.utc].merging(fields) { _, new in new }
        let data = Data(try GateClock.json(manifest).utf8)
        guard data.count <= 4096, bytes + data.count <= limit - 8192 else { throw GateFault.invalid("final manifest bound") }
        if !logClosed { try handle.synchronize(); try handle.close(); logClosed = true }
        // No final Passed name exists until every preceding write/sync/close succeeded.
        let pending = folder.appendingPathComponent("final-pending-" + UUID().uuidString + ".json")
        try data.write(to:pending,options:.withoutOverwriting)
        let final = try FileHandle(forWritingTo:pending); try final.synchronize(); try final.close()
        try FileManager.default.moveItem(at:pending,to:folder.appendingPathComponent("final.json"))
        finalWritten = true
    }
}

nonisolated struct GateArm: Codable, Sendable { let token:UUID; let armedAt:Double }
nonisolated struct GateRelease: Codable, Sendable {
    let token, call: UUID
    let releasedAt: Double
    let reason: String
    let proofSequence: Int
    let proofHash: String
}
actor DiagnosticHoldGate {
    private var arm: GateArm?
    private var waiter: (UUID, CheckedContinuation<GateRelease,Error>)?
    private var closed = false
    func prepare() throws -> GateArm {
        guard arm == nil, !closed else { throw GateFault.invalid("one arm only") }
        let value = GateArm(token:UUID(),armedAt:GateClock.mono); arm = value; return value
    }
    func hold(_ token: UUID, call: UUID, registered: @escaping @MainActor @Sendable (Double) -> Void) async throws -> GateRelease {
        guard arm?.token == token, waiter == nil, !closed else { throw GateFault.invalid("unarmed/extra call") }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = (call,continuation)
            let at = GateClock.mono
            Task { @MainActor in registered(at) } // The continuation is already stored before this ACK can run.
        }
    }
    func release(_ token: UUID, call: UUID, proof: GateLogReceipt) throws -> GateRelease {
        guard arm?.token == token, let held = waiter, held.0 == call, !closed, proof.sequence > 0, proof.hash.count == 64 else { throw GateFault.invalid("release binding") }
        let receipt = GateRelease(token:token,call:call,releasedAt:GateClock.mono,reason:"saved-early-cancel",proofSequence:proof.sequence,proofHash:proof.hash)
        waiter = nil; closed = true; held.1.resume(returning:receipt); return receipt
    }
    func cleanup() {
        closed = true
        if let held = waiter { waiter = nil; held.1.resume(throwing:GateFault.invalid("cleanup-only release")) }
    }
}

nonisolated struct GatePrepared: Codable, Sendable {
    let request, project: UUID
    let payloadHash, selected, source, fileStamp: String
    func matches(_ sample: GateSQLSample) -> Bool {
        guard let job = sample.job else { return false }
        return !job.attempt.isEmpty && !selected.isEmpty && !job.attemptIsNull && !job.selectedIsNull &&
            project.uuidString == job.project && source == job.source &&
            selected == job.selected && fileStamp == job.identity
    }
}
nonisolated struct GateVisible: Sendable { let alive:Bool; let project:UUID?; let busy,loading,canSend:Bool; let request:UUID? }
@MainActor final class GateModelObservation {
    let entry: UUID
    let objectID: String
    weak var model: ProjectMemoryPanelModel?
    weak var owner: GateDiagnosticCoordinator?
    var appeared = false
    private var cancellables: Set<AnyCancellable> = []
    private var previousRequest: GatePrepared?
    private var receivedInitialProject = false
    init(entry: UUID, model: ProjectMemoryPanelModel, owner: GateDiagnosticCoordinator) {
        self.entry = entry; self.model = model; self.owner = owner; objectID = String(describing:ObjectIdentifier(model))
        model.$request.sink { [weak self] value in self?.requestChanged(value) }.store(in:&cancellables)
        model.$projectID.sink { [weak self] value in
            guard let self else { return }
            if !self.receivedInitialProject { self.receivedInitialProject = true; return }
            self.owner?.projectPublished(entry:entry,value:value)
        }.store(in:&cancellables)
        model.$busy.sink { [weak self] value in self?.owner?.busyPublished(entry:entry,value:value) }.store(in:&cancellables)
    }
    private func requestChanged(_ value: MemoryUpdateRequest?) {
        // @Published delivers willSet's new value; never read model.request for that value.
        // No scheduler, Task or await between this sink and the saved send-state marker.
        guard let owner else { return }
        if let value {
            // Request lease/validation are fileprivate. Recompute the public exact
            // selected-input contract from this actual request, never open access.
            let selected = (try? MemoryFactExtractor.producerKey(model:"fake-only",payload:value.payload,hits:value.fragments,parents:value.parents)) ?? ""
            let prepared = GatePrepared(request:value.id,project:value.projectID,payloadHash:GateClock.hash(value.payload),selected:selected,source:value.fragments.first?.source.key.rawValue ?? "",fileStamp:value.fragments.first?.fileStamp ?? "")
            previousRequest = prepared
            owner.prepared(entry:entry,value:prepared,valid:value.fragments.count == 1 && value.parents.isEmpty && !value.denied && value.approvalProjectIDs == Set([value.projectID]))
        } else if let old = previousRequest {
            previousRequest = nil
            owner.requestCleared(entry:entry,previous:old,busy:model?.busy == true,mainThread:Thread.isMainThread)
        }
    }
    func read() -> GateVisible {
        guard let model else { return GateVisible(alive:false,project:nil,busy:false,loading:false,canSend:false,request:nil) }
        return GateVisible(alive:true,project:model.projectID,busy:model.busy,loading:model.loading,canSend:model.canSend,request:model.request?.id)
    }
    func stop() { cancellables.removeAll() }
    func cleanupClose() { model?.close() }
}

@MainActor final class GateDiagnosticClient: ChatCompleter {
    weak var owner: GateDiagnosticCoordinator?
    let gate = DiagnosticHoldGate()
    private(set) var calls = 0
    nonisolated func complete(model:String,messages:[ChatMessage],responseFormat:ResponseFormat?) async throws -> String {
        do {
            let reply = try await send(messages)
            await owner?.adapterCompleteBoundary(error:nil)
            return reply
        } catch {
            await owner?.adapterCompleteBoundary(error:String(describing:error))
            throw error
        }
    }
    private func send(_ messages:[ChatMessage]) async throws -> String {
        calls += 1
        guard calls == 1, let owner else { throw GateFault.invalid("single physical attempt only") }
        let payload = messages.last?.content ?? ""
        let binding = try owner.adapterEntered(payload:payload)
        let release = try await gate.hold(binding.token,call:binding.call) { [weak owner] at in owner?.heldRegistered(call:binding.call,token:binding.token,actorAt:at) }
        try owner.adapterReplyReady(release)
        // Deliberately noncooperative fake: return a valid late reply after cancellation.
        let input = try JSONSerialization.jsonObject(with:Data(payload.utf8)) as? [String:Any]
        guard let fragments = input?["fragments"] as? [[String:Any]], fragments.count == 1,
              let text = fragments[0]["text"] as? String, let label = fragments[0]["label"] as? String else { throw GateFault.invalid("fake payload shape") }
        let fact:[String:Any] = ["subject":"gate:one","kind":"agreement","conditions":[:],"text":text,"action":"assertion","deadline":NSNull(),"decisionDate":NSNull(),"evidence":[["source":label,"quote":text]],"links":[]]
        return String(decoding:try JSONSerialization.data(withJSONObject:["insufficientEvidence":false,"facts":[fact]]),as:UTF8.self)
    }
}

@MainActor final class GateDiagnosticCoordinator: ObservableObject {
    enum Phase: String { case preparing, ready, armed, recordingRunning, choosePrivate, releasing, awaitBack, awaitWeak, awaitReopen, awaitPreview, passed, inconclusive }
    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var status = "Подготовка одной synthetic встречи…"
    @Published private(set) var remaining = 300
    @Published private(set) var route: UUID?
    @Published private(set) var rootError: String?
    @Published private(set) var projectLibrary: ProjectLibrary?
    private var log: GateLog?
    private var store: ProjectStore?
    private var worker: ProjectMemoryQueueWorker?
    private var reader: GateSQLReader?
    private let client = GateDiagnosticClient()
    private var north: UUID?, privateProject: UUID?
    private var observations: [UUID:GateModelObservation] = [:]
    private var appearedEntries: Set<UUID> = []
    private var firstEntry: UUID?, closedEntry: UUID?
    private var preparedValue: GatePrepared?, originalRequest: GatePrepared?
    private var arm: GateArm?, call: UUID?
    private var heldAt: Double?, sendMarker: Double?, projectMarker: Double?
    private var anchor: GateSQLSample?, running: GateSQLSample?, latestNeedsConsent: GateSQLSample?
    private var initialBaseline: GateSQLSample?
    private var preparedEntry: UUID?, preparedObservedAt: Double?, preparedReceipt: GateLogReceipt?
    private var baselineProjects: [[String]]?
    private var proof: GateLogReceipt?, releaseReceipt: GateRelease?
    private var physicalReturn = false
    private var failure: String?, finished = false, releaseRequested = false
    private let launched = GateClock.mono
    private var monitor: Task<Void,Never>?
    private var lastSignature = "", lastHeartbeat = 0.0
    var terminal: Bool { phase == .passed || phase == .inconclusive }
    var mayOpen: Bool { !terminal && route == nil && (phase == .ready || phase == .awaitReopen) }
    var mayArm: Bool { !terminal && phase == .ready && arm == nil && route.map { appearedEntries.contains($0) } == true }
    var evidencePath: String { AppPaths.appSupport.path }
    init() {
        guard AppRuntime.isTestHost else { phase = .inconclusive; status = "Test host guard отсутствует"; return }
        do { log = try GateLog(folder:AppPaths.appSupport); try record("session-start",["mode":"one synthetic meeting; no hidden model; no PDF/OCR/ONNX inference"]) }
        catch { phase = .inconclusive; status = "INCONCLUSIVE: \(error)"; rootError = status; return }
        client.owner = self
        Task { [weak self] in await self?.setup() }
    }
    @discardableResult private func record(_ name:String,_ fields:[String:String] = [:],sample:GateSQLSample? = nil) throws -> GateLogReceipt {
        guard let log else { throw GateFault.invalid("no logger") }
        return try log.append(name,fields,sample:sample)
    }
    private func setup() async {
        do {
            let store = ProjectStore(url:AppPaths.appSupport.appendingPathComponent("knowledge.sqlite")); self.store = store
            let projects = ProjectLibrary(store:store); projectLibrary = projects
            let n = try await store.createProject(name:"Север"), p = try await store.createProject(name:"Приватный")
            north = n.id; privateProject = p.id
            try await store.setCloudPolicy(.askEveryTime,for:n.id); try await store.setCloudPolicy(.localOnly,for:p.id)
            let folder = AppPaths.meetingsRoot.appendingPathComponent("current")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let text = "Синтетический контроль: проверить отмену одного согласованного обновления."
            try JSONSerialization.data(withJSONObject:["meetingId":"current","segments":[["start":42.5,"end":55.0,"text":text]]]).write(to:folder.appendingPathComponent("transcript.json"),options:.atomic)
            _ = try await MeetingEmbeddingSnapshotReader(root:AppPaths.meetingsRoot).synchronize(meetingID:"current",store:store)
            try await store.assignMeeting("current",to:[n.id])
            let model = EmbeddingIndexModel(id:"synthetic-gate-2d",dimensions:2)
            try await store.activateEmbeddingModel(model)
            var syntheticJobs = 0
            while let lease = try await store.claimEmbeddingJob() {
                guard syntheticJobs == 0, lease.snapshot.chunks.count == 1 else { throw GateFault.invalid("one synthetic source only") }; syntheticJobs += 1
                let values = try lease.snapshot.chunks.map { IndexedChunkVectors(chunkID:$0.id,bodyTokenCount:1,windows:[.init(tokenStart:0,tokenCount:1,vector:try KnowledgeVector(modelID:model.id,values:[1,0]))]) }
                guard try await store.publishEmbeddingVectors(values,lease:lease) else { throw GateFault.invalid("synthetic publish fence") }
            }
            let worker = ProjectMemoryQueueWorker(store:store,meetingsRoot:AppPaths.meetingsRoot,documentsRoot:AppPaths.appSupport.appendingPathComponent("copies"),client:client,model:"fake-only")
            self.worker = worker; reader = GateSQLReader(url:AppPaths.appSupport.appendingPathComponent("knowledge.sqlite"))
            await projects.reload()
            await worker.start(); await worker.waitUntilIdle() // Setup only, never approval completion proof.
            let sample = try await reader!.read(); baselineProjects = sample.projects
            try record("fresh-initial-baseline",["meaning":"before actual UI prepare; SQL NULL flags preserved"],sample:sample)
            guard sample.historyCount == 0, sample.jobs.count == 1, sample.job?.project == n.id.uuidString, sample.job?.source == "meeting:current", sample.job?.cursor == "0", sample.job?.total == "1", sample.job?.state == "needsConsent", sample.job?.attemptIsNull == true, sample.job?.selectedIsNull == true, sample.job?.attempt.isEmpty == true, sample.job?.selected.isEmpty == true, !sample.run.isEmpty, client.calls == 0 else { throw GateFault.invalid("fresh seed/needsConsent baseline") }
            initialBaseline = sample
            try record("setup-complete",["workerIdleMeaning":"setup only"],sample:sample)
            phase = .ready; status = "1. Откройте «Память». 2. Подготовьте контроль удержания. 3. В очереди просмотрите контекст и прочитайте его до согласия."
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    guard await self?.tick() == true else { break }
                    do { try await Task.sleep(for:.milliseconds(100)) } catch { break }
                }
            }
        } catch { fail("setup: \(error)") }
    }
    func openRoute() {
        guard mayOpen else { return }
        let id = UUID(); route = id
        if firstEntry == nil { firstEntry = id }
        do { try record("host-route-open",["entry":id.uuidString]) } catch { fail("route log: \(error)") }
    }
    func back(_ entry:UUID) {
        guard route == entry else { fail("foreign back"); return }
        do { try record("actual-onBack",["entry":entry.uuidString]) } catch { fail("back log: \(error)") }
        route = nil
        if !terminal, phase != .awaitBack { fail("entry closed before late-return proof") }
    }
    func factory(entry:UUID,project:UUID?,meeting:String?) -> ProjectMemoryPanelModel? {
        guard route == entry, let store, let worker, project == north, meeting == nil, !terminal else { fail("factory route binding"); return nil }
        let model = ProjectMemoryPanelModel(store:store,worker:worker,meetingsRoot:AppPaths.meetingsRoot,documentsRoot:AppPaths.appSupport.appendingPathComponent("copies"),projectID:project,provider:"Fake · без сети",center:.default)
        let observation = GateModelObservation(entry:entry,model:model,owner:self)
        observation.appeared = appearedEntries.contains(entry); observations[entry] = observation
        do { try record("actual-returned-model",["entry":entry.uuidString,"object":observation.objectID,"project":project?.uuidString ?? "nil"]) }
        catch { fail("factory log: \(error)") }
        return model
    }
    func appeared(_ entry:UUID) {
        appearedEntries.insert(entry); observations[entry]?.appeared = true
        do { try record("entry-appear",["entry":entry.uuidString]) } catch { fail("appear log: \(error)") }
        if phase == .ready { status = "Видимый entry открыт. Подготовьте контроль удержания и прочитайте точный preview до единственного согласия." }
        if phase == .awaitReopen { phase = .awaitPreview; status = "Новый entry. Откройте «Очередь». При необходимости нажмите «Повторить обработку», затем «Просмотреть контекст». Второе согласие НЕ давайте." }
    }
    func disappeared(_ entry:UUID) {
        appearedEntries.remove(entry); observations[entry]?.appeared = false; observations[entry]?.stop()
        do { try record("entry-disappear",["entry":entry.uuidString]) } catch { fail("disappear log: \(error)") }
        if !terminal, phase == .awaitBack { closedEntry = entry; phase = .awaitWeak; status = "Проверяем weak lifetime старого entry…" }
    }
    func prepareGate() {
        guard mayArm, route != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await client.gate.prepare()
                try record("actor-arm-ACK",["token":receipt.token.uuidString,"actorAt":String(receipt.armedAt)])
                arm = receipt; phase = .armed
                status = "Удержание готово · token \(receipt.token.uuidString.prefix(8)). Прочитайте весь контекст. Только затем разрешите отправку этой части один раз."
            } catch { fail("arm: \(error)") }
        }
    }
    func prepared(entry:UUID,value:GatePrepared,valid:Bool) {
        guard !terminal, route == entry else { return }
        guard valid, value.project == north, !value.selected.isEmpty, value.source == "meeting:current", !value.fileStamp.isEmpty else { fail("prepared request boundary"); return }
        preparedValue = value; preparedEntry = entry; preparedObservedAt = GateClock.mono
        preparedReceipt = nil; latestNeedsConsent = nil
        do { try record("prepared-request",["entry":entry.uuidString,"request":value.request.uuidString,"payloadSHA256":value.payloadHash,"selectedInputKey":value.selected,"source":value.source,"fileStamp":value.fileStamp]) }
        catch { fail("prepared log: \(error)") }
    }
    func requestCleared(entry:UUID,previous:GatePrepared,busy:Bool,mainThread:Bool) {
        guard !terminal, busy else { return } // invalidate/cancel clears busy first; it is not consent.
        guard phase == .armed, let arm, route == entry, observations[entry]?.appeared == true, mainThread,
              preparedEntry == entry, preparedValue?.request == previous.request, let preparedReceipt, let observed = preparedObservedAt,
              let fresh = latestNeedsConsent, fresh.began >= observed, previous.matches(fresh),
              fresh.job?.state == "needsConsent", GateClock.mono - fresh.began < 1 else { fail("send marker without armed/visible/prepared lease/fresh needsConsent proof"); return }
        do {
            originalRequest = previous; sendMarker = GateClock.mono; anchor = fresh
            try record("observed-send-state-before-operation-task",["entry":entry.uuidString,"request":previous.request.uuidString,"token":arm.token.uuidString,"preparedReceipt":try GateClock.json(preparedReceipt),"markerKind":"Published request nil with busy already true; not mouse click"],sample:fresh)
            phase = .recordingRunning; status = "Фиксируем первый running. Не меняйте проект до ACK удержанного вызова."
        } catch { fail("send marker log: \(error)") }
    }
    func projectPublished(entry:UUID,value:UUID?) {
        guard !terminal, originalRequest != nil, route == entry else { return }
        do { try record("actual-picker-willSet",["entry":entry.uuidString,"publishedProject":value?.uuidString ?? "nil","semantics":"new value, before didSet; post-set model read required"]) }
        catch { fail("project log: \(error)") }
        if value == privateProject { projectMarker = GateClock.mono }
        else if value != north { fail("unexpected project transition") }
    }
    func busyPublished(entry:UUID,value:Bool) {
        guard !terminal, originalRequest != nil else { return }
        do { try record("actual-model-busy-willSet",["entry":entry.uuidString,"newBusy":String(value)]) } catch { fail("busy log: \(error)") }
    }
    func adapterEntered(payload:String) throws -> (token:UUID,call:UUID) {
        guard !terminal, let arm, let request = originalRequest, sendMarker != nil, phase == .recordingRunning,
              GateClock.hash(payload) == request.payloadHash, client.calls == 1, payload.utf8.count <= 2048 else { throw GateFault.invalid("adapter request/token/payload binding") }
        let id = UUID(); call = id
        try record("adapter-enter",["call":id.uuidString,"request":request.request.uuidString,"token":arm.token.uuidString,"payload":payload,"payloadSHA256":GateClock.hash(payload)])
        return (arm.token,id)
    }
    func heldRegistered(call:UUID,token:UUID,actorAt:Double) {
        guard !terminal, self.call == call, arm?.token == token else { fail("held ACK binding"); return }
        heldAt = actorAt
        do { try record("physical-held-waiter-registered-ACK",["call":call.uuidString,"token":token.uuidString,"actorAt":String(actorAt)]) } catch { fail("held log: \(error)") }
    }
    func adapterReplyReady(_ release:GateRelease) throws {
        guard failure == nil, releaseRequested, release.reason == "saved-early-cancel", release.call == call, release.token == arm?.token,
              release.proofSequence == proof?.sequence, release.proofHash == proof?.hash else { throw GateFault.invalid("physical reply without saved early cancellation") }
        try record("adapter-after-actor-release",["release":try GateClock.json(release)])
    }
    func adapterCompleteBoundary(error:String?) {
        physicalReturn = true
        do { try record("adapter-physical-return-boundary",["call":call?.uuidString ?? "none","error":error ?? "none","physicalCalls":String(client.calls),"boundary":"last wrapper boundary before returning to actual service"]) }
        catch { fail("return log: \(error)") }
        if error != nil, failure == nil { fail("adapter returned error") }
    }
    private func tick() async -> Bool {
        guard !terminal, let reader else { return false }
        do {
            let sample = try await reader.read()
            guard sample.projects == baselineProjects, sample.historyCount == 0, sample.history.isEmpty, sample.jobs.count == 1,
                  sample.job?.source == "meeting:current", sample.job?.cursor == "0", sample.job?.total == "1" else { throw GateFault.invalid("SQL identity/history/source boundary") }
            if let original = anchor, let before = original.job, let now = sample.job {
                guard before.sameIdentity(as:now), original.run == sample.run else { throw GateFault.invalid("same-job identity/run reset") }
            }
            let signature = try GateClock.json(sample.jobs)
            if signature != lastSignature { try record("sql-state-change",sample:sample); lastSignature = signature }
            if let sendMarker {
                let bound = anchor?.began ?? latestNeedsConsent?.began ?? sendMarker
                let elapsed = sample.ended - bound
                let seconds = max(0,Int((releaseRequested ? 45-(sample.ended-sendMarker) : 20-elapsed).rounded(.up))); if remaining != seconds { remaining = seconds }
                if !releaseRequested, elapsed >= 20 { throw GateFault.invalid("earlycancel20s budget exceeded") }
                if sample.ended - sendMarker > 45 { throw GateFault.invalid("actual case45s budget exceeded") }
            } else {
                let seconds = max(0,300-Int(GateClock.mono-launched)); if remaining != seconds { remaining = seconds }
                if GateClock.mono-launched > 300 { throw GateFault.invalid("preparation5min budget exceeded") }
            }
            if GateClock.mono-lastHeartbeat >= 5 { try record("bounded-heartbeat",["phase":phase.rawValue]); lastHeartbeat = GateClock.mono }
            if sendMarker == nil, let prepared = preparedValue, let observed = preparedObservedAt,
               sample.began >= observed, sample.job?.state == "needsConsent" {
                guard let initial = initialBaseline, let before = initial.job, let now = sample.job,
                      before.sameIdentity(as:now), before.generation == now.generation, initial.run == sample.run,
                      prepared.matches(sample), preparedEntry == route,
                      route.flatMap({ observations[$0]?.read().request }) == prepared.request else { throw GateFault.invalid("prepared needsConsent lease/request mismatch") }
                if preparedReceipt == nil {
                    preparedReceipt = try record("prepared-lease-receipt",["entry":preparedEntry!.uuidString,"request":prepared.request.uuidString,"payloadSHA256":prepared.payloadHash,"preparedObservedAt":String(observed),"meaning":"after actual UI prepare; before send marker/anchor"],sample:sample)
                }
                latestNeedsConsent = sample
            }
            if phase == .recordingRunning, sample.job?.state == "running" {
                guard let previous = anchor, let before = previous.job, let now = sample.job,
                      before.sameIdentity(as:now), !before.attemptIsNull, !now.attemptIsNull, !before.selectedIsNull, !now.selectedIsNull,
                      !before.attempt.isEmpty, before.attempt == now.attempt, !before.selected.isEmpty, before.selected == now.selected, before.generation == now.generation, previous.run == sample.run,
                      previous.ended <= sendMarker!, sample.ended >= sendMarker! else { throw GateFault.invalid("missing/mismatched first running or anchor") }
                anchor = previous; running = sample
                try record("first-running-freeze",["needsConsentAnchor":try GateClock.json(previous),"budgetAnchor":"needsConsent READ BEGIN; not fake entry"],sample:sample)
            }
            if phase == .recordingRunning, heldAt != nil, running != nil {
                phase = .choosePrivate; status = "Вызов1 действительно удерживается. Сейчас выберите «Приватный» в настоящем Picker панели. Release будет только после сохранённой ранней отмены."
            }
            if phase == .choosePrivate, let entry = route, let observation = observations[entry], let marker = projectMarker,
               observation.read().project == privateProject, sample.job?.state == "cancelled" {
                guard let before = running?.job, let now = sample.job, let anchor,
                      before.sameIdentity(as:now), now.attempt.isEmpty, now.generation != before.generation,
                      sample.run == running?.run, sample.began >= marker, sample.ended-anchor.began < 20,
                      now.message == "Отменено пользователем.", client.calls == 1 else { throw GateFault.invalid("early durable cancellation criterion") }
                proof = try record("early-cancel-saved",["elapsedFromAnchorReadBegin":String(sample.ended-anchor.began),"project":privateProject!.uuidString],sample:sample)
                releaseRequested = true; phase = .releasing; status = "Early cancel сохранён. Diagnostic coordinator освобождает только этот held call…"
                try record("diagnostic-release-request",["proof":try GateClock.json(proof!)])
                releaseReceipt = try await client.gate.release(arm!.token,call:call!,proof:proof!)
                try record("actor-release-ACK",["receipt":try GateClock.json(releaseReceipt!)])
            }
            if phase == .releasing, physicalReturn, releaseReceipt != nil {
                guard sample.job?.state == "cancelled", sample.historyCount == 0, client.calls == 1 else { throw GateFault.invalid("late publication or unrelated state") }
                try record("late-result-not-published",sample:sample)
                phase = .awaitBack; status = "Поздний ответ вернулся, history0/calls1. Нажмите «К проекту», затем «Память». Не давайте второе согласие."
            }
            if phase == .awaitWeak, let old = closedEntry, observations[old]?.read().alive == false {
                try record("old-visible-model-weak-nil",["entry":old.uuidString])
                phase = .awaitReopen; status = "Старый model освобождён. Нажмите «Память», затем при необходимости Retry и Просмотреть контекст. Второго send не нужно."
            }
            if phase == .awaitPreview, let id = route, id != firstEntry, let state = observations[id]?.read(), state.alive, state.canSend,
               let request = state.request, request != originalRequest?.request, sample.job?.state == "needsConsent" {
                guard let original = anchor?.job, let now = sample.job, original.sameIdentity(as:now), !now.attempt.isEmpty, now.attempt != original.attempt,
                      state.project == north, client.calls == 1, physicalReturn, closedEntry != nil,
                      observations[closedEntry!]?.read().alive == false else { throw GateFault.invalid("fresh preview / weak lifetime / approval idle proof") }
                try record("fresh-preview-approval-idle-receipt",["entry":id.uuidString,"request":request.uuidString,"receipt":"canApprovePreview true => active=nil, worker=nil, loadingPreview=false; old weak model nil; not waitUntilIdle alone"],sample:sample)
                let code = await reader.close(); guard code == SQLITE_OK else { throw GateFault.invalid("readonly native close \(code)") }
                try record("readonly-sensor-close",["result":String(code)])
                guard let log else { throw GateFault.invalid("missing final logger") }
                try log.finish(status:"Passed",fields:["claim":"one early-cancel/late-return/weak-old-entry/fresh-preview case","call":call!.uuidString,"request":originalRequest!.request.uuidString,"normalComposition":"not run","actualWidthExtrema":"not tested"])
                finished = true; phase = .passed; status = "PASSED — один case записан. Новый preview не имеет старого согласия; второй send не выполнялся. Остановитесь и передайте final.json координатору."
                return false
            }
            return !terminal
        } catch { fail("capture: \(error)"); return false }
    }
    private func fail(_ message:String) {
        let reason = String(message.prefix(512))
        guard failure == nil, !finished else { return }
        failure = reason; phase = .inconclusive; status = "INCONCLUSIVE — \(reason). Cleanup отдельно, не доказательство отмены."; rootError = reason
        _ = try? record("case-inconclusive",["reason":reason])
        monitor?.cancel()
        Task { [weak self] in
            guard let self else { return }
            _ = try? record("cleanup-only-begin")
            for observation in observations.values { observation.cleanupClose(); observation.stop() }
            await client.gate.cleanup()
            await worker?.stop() // Do not call this a successful approval join.
            let close = await reader?.close()
            _ = try? record("cleanup-only-end",["readonlyClose":close.map(String.init) ?? "none","physicalBoundaryObserved":String(physicalReturn)])
            do { try log?.finish(status:"INCONCLUSIVE",fields:["reason":reason,"cleanupIsProof":"false"]) }
            catch { rootError = "\(reason); final write failure: \(error)" }
        }
    }
    func windowDisappeared() { if !terminal { fail("window closed before final proof") } }
}

struct GateDiagnosticEntry: View {
    @ObservedObject var owner: GateDiagnosticCoordinator
    let entry: UUID
    let project: UUID
    var body: some View {
        ProjectMemoryEntry(projectID:project,meetingID:nil,onBack:{ owner.back(entry) },onSettings:nil,
            makeModel:{ [weak owner] p,m in owner?.factory(entry:entry,project:p,meeting:m) })
            .onAppear { owner.appeared(entry) }.onDisappear { owner.disappeared(entry) }
    }
}
struct GateDiagnosticRoot: View {
    @ObservedObject var owner: GateDiagnosticCoordinator
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Один self-recording контроль · только synthetic/fake").font(.title2)
            Text(owner.status).foregroundStyle(owner.phase == .inconclusive ? Color.red : owner.phase == .passed ? Color.green : Color.primary).textSelection(.enabled)
            Text("Осталось: \(owner.remaining) с · phase \(owner.phase.rawValue)").monospacedDigit()
            HStack {
                Button("Подготовить контроль удержания") { owner.prepareGate() }.disabled(!owner.mayArm)
                ProjectMemoryOpenButton(title:"Память",systemImage:"text.book.closed",identifier:"gate.open") { owner.openRoute() }.disabled(!owner.mayOpen)
            }
            Text("До согласия можно спокойно прочитать весь preview (до5мин). После ACK физического held-call выберите Приватный без переписки. После release — К проекту → Память → новый preview, без второго согласия. Любая ошибка/overflow остаётся INCONCLUSIVE.").font(.callout)
            Text(owner.evidencePath).font(.caption).textSelection(.enabled)
            Divider()
            GateRouteContent(owner:owner)
                .disabled(owner.terminal)
        }.padding(18).frame(minWidth:850,minHeight:760)
            .environment(\.palette,Palette.light).preferredColorScheme(.light)
            .onDisappear { owner.windowDisappeared() }
    }
}
struct GateRouteContent: View {
    @ObservedObject var owner: GateDiagnosticCoordinator
    var body: some View {
        if let entry = owner.route, let project = owner.initialProject, let library = owner.projectLibrary {
            // Initial project comes from the fresh seed. Picker changes remain actual model/UI actions.
            GateDiagnosticEntry(owner:owner,entry:entry,project:project).environmentObject(library)
        } else { ContentUnavailableView("Откройте память для одного локального контроля",systemImage:"text.book.closed") }
    }
}
extension GateDiagnosticCoordinator {
    var initialProject: UUID? { north }
}
struct GateDiagnosticApp: App {
    @StateObject private var owner = GateDiagnosticCoordinator()
    var body: some Scene { WindowGroup("Golos Memory Gate Diagnostics · Synthetic") { GateDiagnosticRoot(owner:owner) }.defaultSize(width:1080,height:880) }
}
@main struct GateDiagnosticMain {
    static func main() { setenv("GOLOS_MEET_TEST_MODE","1",1); GateDiagnosticApp.main() }
}
