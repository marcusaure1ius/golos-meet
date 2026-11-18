import Foundation

extension ProjectStore {
    func startMemoryQueueRun() throws -> String {
        try memoryTransaction { db in
            let run = UUID().uuidString
            try db.execute("UPDATE memory_queue_runtime SET generation=? WHERE slot=1", bindings: [run])
            try db.execute("UPDATE memory_queue_work SET state=CASE WHEN cursor>0 THEN 'partial' ELSE 'queued' END,generation=lower(hex(randomblob(16))),attempt=NULL,message='Восстановлено после остановки.' WHERE state='running'")
            return run
        }
    }
    func memoryQueueSnapshot(projectID: UUID? = nil, limit: Int = 256) throws -> MemoryQueueSnapshot {
        guard (1...256).contains(limit) else { throw MemoryQueueError.budget }
        return try memoryTransaction { db in
            let rows = try db.rows(MemoryQueueSQL.select + (projectID == nil ? "" : " WHERE project_id=?") + " ORDER BY sequence LIMIT ?", bindings: (projectID.map { [$0.uuidString] } ?? []) + [String(limit + 1)])
            return .init(jobs: try rows.prefix(limit).map(MemoryQueueSQL.job), backpressured: rows.count > limit || rows.contains(where: { $0[6] == "backpressured" }))
        }
    }
    /// Catalog + bounded consumed-proof reconciliation; file identities use lstat.
    /// Completed rows do not depend on automatically changing journal heads.
    func reconcileMemoryQueue(catalog: KnowledgeSearchCatalog, identities: [EmbeddingSourceKey: String], generatorModel: String, contract: String, run: String? = nil) throws {
        guard !generatorModel.isEmpty, generatorModel.count <= 256 else { throw MemoryQueueError.budget }
        try memoryTransaction { db in
            try MemoryQueueSQL.requireRun(run, db: db)
            let activeModel = try db.rows("SELECT model_id,dimensions FROM embedding_active_model WHERE slot=1").first
            let epoch = try db.rows("SELECT generation FROM knowledge_model_epoch WHERE slot=1").first?.first
            guard epoch == catalog.model.generation,
                  activeModel?.first == catalog.model.model?.id else { throw MemoryQueueError.stale }
            var activeCount = Int(try db.rows("SELECT COUNT(*) FROM memory_queue_work WHERE state IN ('queued','partial','running')").first?.first ?? "") ?? 0
            var present: Set<String> = []
            let empty = try MemoryEncoding.encode(MemoryQueueDependencies())
            for source in catalog.sources {
                for project in source.owners.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let id = project.uuidString + "|" + source.key.rawValue; present.insert(id)
                    let stamp = identities[source.key] ?? "unavailable"
                    var value = try MemoryQueueSQL.input(project: project, source: source.key, model: generatorModel, contract: contract, identity: stamp, db: db)
                    if value.state == .queued, activeCount >= 128 { value.state = .backpressured; value.message = "Очередь заполнена; источник ждёт свободного места." }
                    let bindings = [project.uuidString, source.key.rawValue]
                    let old = try db.rows(MemoryQueueSQL.select + " WHERE project_id=? AND source_key=?", bindings: bindings).first
                    let raw = try db.rows("SELECT dependencies,identity FROM memory_queue_work WHERE project_id=? AND source_key=?", bindings: bindings).first
                    var changed = old?.dropFirst(4).first != value.hash
                    if let raw {
                        let deps = try MemoryEncoding.decode(MemoryQueueDependencies.self, raw[0])
                        if try !MemoryQueueSQL.dependenciesCurrent(deps, identities: identities, db: db) { changed = true }
                    }
                    if old == nil {
                        if value.state == .queued { activeCount += 1 }
                        try db.execute("INSERT INTO memory_queue_work(project_id,source_key,source,input,generation,state,cursor,total,identity,generator_model,generator_contract,cycle,dependencies,message) VALUES (?,?,?,?,?,?,0,?,?,?,?,?,?,?)", bindings: bindings + [try MemoryEncoding.encode(source.key), value.hash, UUID().uuidString, value.state.rawValue, String(value.total), stamp, generatorModel, contract, UUID().uuidString, empty, value.message])
                    } else if changed, let old {
                        let previous = try MemoryQueueSQL.job(old)
                        if [.queued,.partial,.running].contains(previous.state) { activeCount -= 1 }
                        if value.state == .queued { activeCount += 1 }
                        let state = previous.state == .cancelled ? .cancelled : value.state
                        try db.execute("UPDATE memory_queue_work SET input=?,generation=?,state=?,cursor=0,total=?,identity=?,generator_model=?,generator_contract=?,cycle=?,dependencies=?,selected_key=NULL,message=?,attempt=NULL WHERE project_id=? AND source_key=?", bindings: [value.hash, UUID().uuidString, state.rawValue, String(value.total), stamp, generatorModel, contract, UUID().uuidString, empty, value.message] + bindings)
                    } else if let old, [.waiting,.backpressured].contains(try MemoryQueueSQL.job(old).state), value.state == .queued {
                        activeCount += 1
                        try db.execute("UPDATE memory_queue_work SET state=CASE WHEN cursor>0 THEN 'partial' ELSE 'queued' END,message='' WHERE project_id=? AND source_key=?", bindings: bindings)
                    }
                }
            }
            for row in try db.rows(MemoryQueueSQL.select) {
                let job = try MemoryQueueSQL.job(row)
                if !present.contains(job.id), job.state != .cancelled, job.state != .stale {
                    try db.execute("UPDATE memory_queue_work SET state='stale',generation=?,attempt=NULL,message='Источник удалён или больше не принадлежит проекту.' WHERE sequence=?", bindings: [UUID().uuidString, String(job.sequence)])
                }
            }
        }
    }
    func claimMemoryQueue(run: String, after: Int64?, explicit sequence: Int64? = nil, excluding project: UUID? = nil) throws -> MemoryQueueLease? {
        try memoryTransaction { db in
            guard try db.rows("SELECT generation FROM memory_queue_runtime WHERE slot=1").first?.first == run else { throw MemoryQueueError.stale }
            let row: [String]?
            if let sequence { row = try db.rows(MemoryQueueSQL.select + " WHERE sequence=? AND state IN ('needsConsent','queued','partial','backpressured','failed','stale','limited','insufficient','completed','cancelled')", bindings: [String(sequence)]).first }
            else {
                row = try db.rows(MemoryQueueSQL.select + " WHERE state IN ('queued','partial','backpressured')" + (project == nil ? "" : " AND project_id!=?") + " ORDER BY CASE WHEN sequence>? THEN 0 ELSE 1 END,sequence LIMIT 1", bindings: (project.map { [$0.uuidString] } ?? []) + [String(after ?? 0)]).first
            }
            guard let row else { return nil }; let job = try MemoryQueueSQL.job(row)
            let extra = try db.rows("SELECT identity,generator_model,generator_contract FROM memory_queue_work WHERE sequence=?", bindings: [String(job.sequence)])[0]
            let current = try MemoryQueueSQL.input(project: job.projectID, source: job.source, model: extra[1], contract: extra[2], identity: extra[0], db: db)
            guard current.hash == job.input, job.completedChunks < job.totalChunks else { throw MemoryQueueError.stale }
            let chunks = try db.rows("SELECT text FROM embedding_chunks WHERE source_key=? ORDER BY ordinal,id LIMIT 12 OFFSET ?", bindings: [job.source.rawValue, String(job.completedChunks)])
            var count = 0, characters = 0
            for chunk in chunks {
                guard characters + chunk[0].count <= 14_000 else { break }; count += 1; characters += chunk[0].count
            }
            if count == 0 {
                try db.execute("UPDATE memory_queue_work SET state='limited',message=? WHERE sequence=?", bindings: [MemoryQueueError.budget.localizedDescription, String(job.sequence)])
                return nil
            }
            let attempt = UUID().uuidString
            try db.execute("UPDATE memory_queue_work SET state='running',attempt=?,message='' WHERE sequence=?", bindings: [attempt, String(job.sequence)])
            return .init(runID: run, attempt: attempt, job: job, count: count, fileStamp: extra[0])
        }
    }
    func memoryQueueChunks(_ lease: MemoryQueueLease) throws -> [KnowledgeChunk] {
        try memoryTransaction { db in
            try MemoryQueueSQL.validate(lease, db: db)
            return try db.rows("SELECT id,source_id,revision,ordinal,text,location FROM embedding_chunks WHERE source_key=? ORDER BY ordinal,id LIMIT ? OFFSET ?", bindings: [lease.job.source.rawValue, String(lease.count), String(lease.job.completedChunks)]).map { row in
                guard let source = UUID(uuidString: row[1]), let ordinal = Int(row[3]) else { throw MemoryQueueError.stale }
                return .init(id: row[0], sourceID: source, revision: row[2], ordinal: ordinal, text: row[4], location: try JSONDecoder().decode(KnowledgeLocation.self, from: Data(row[5].utf8)))
            }
        }
    }
    func bindMemoryQueueInput(_ lease: MemoryQueueLease, memory: MemoryLease, guard expected: MemoryUpdateGuard) throws {
        try memoryTransaction(validating: expected.hits) { db in
            try MemorySQL.validate(memory, db: db); try MemoryQueueSQL.validate(lease, db: db)
            var deps = try MemoryQueueSQL.dependencies(lease, db: db)
            for hit in expected.hits {
                let ref = try MemorySourceReference(hit: hit)
                if let old = deps.sources.first(where: { $0.source.key == ref.key }) {
                    guard old.source.generation == ref.generation, old.source.revision == ref.revision, old.source.fileStamp == ref.fileStamp, old.jobGeneration == hit.source.job.generation else { throw MemoryQueueError.stale }
                } else { deps.sources.append(.init(source: ref, jobGeneration: hit.source.job.generation, modelID: hit.source.job.modelID)) }
            }
            deps.projects = Array(Dictionary((deps.projects + expected.checkpoint.projects).map { ($0.id,$0) }, uniquingKeysWith: { _, latest in latest }).values).sorted { $0.id.uuidString < $1.id.uuidString }
            let ids = Set(deps.manual.map(\.projectID)).union(expected.checkpoint.parentVersions.map(\.projectID)).union([memory.projectID])
            deps.manual = try ids.sorted { $0.uuidString < $1.uuidString }.map { .init(projectID: $0, sequence: try MemoryQueueSQL.manualVersion($0, db: db)) }
            var closure = Set(deps.memories ?? []), pending = memory.parents.map(\.id)
            while let id = pending.popLast() {
                guard closure.insert(id).inserted else { continue }
                guard closure.count <= 256 else { throw MemoryQueueError.budget }
                pending += try MemorySQL.event(id, db: db).parentEventIDs
            }
            deps.memories = closure.sorted { $0.uuidString < $1.uuidString }
            guard deps.sources.count <= 128, deps.sources.reduce(0, { $0 + $1.source.chunk.text.count }) <= 128_000, deps.projects.count <= 128 else { throw MemoryQueueError.budget }
            try db.execute("UPDATE memory_queue_work SET dependencies=?,selected_key=? WHERE sequence=?", bindings: [try MemoryEncoding.encode(deps), memory.producerKey, String(lease.job.sequence)])
        }
    }
    func memoryQueueRunCurrent(_ run: String) throws -> Bool {
        try memoryTransaction { try $0.rows("SELECT generation FROM memory_queue_runtime WHERE slot=1").first?.first == run }
    }
    func hasMemoryQueueWork(excluding project: UUID? = nil) throws -> Bool {
        try memoryTransaction { db in
            try !db.rows("SELECT 1 FROM memory_queue_work WHERE state IN ('queued','partial','backpressured')" + (project == nil ? "" : " AND project_id!=?") + " LIMIT 1", bindings: project.map { [$0.uuidString] } ?? []).isEmpty
        }
    }
    func validateMemoryQueue(_ lease: MemoryQueueLease) throws {
        try memoryTransaction { try MemoryQueueSQL.validate(lease, db: $0) }
    }
    func memoryQueueProof(_ lease: MemoryQueueLease) throws -> [MemorySourceReference] {
        try memoryTransaction { db in try MemoryQueueSQL.validate(lease, db: db); return try MemoryQueueSQL.dependencies(lease, db: db).sources.map(\.source) }
    }
    func finishMemoryQueueWithoutFacts(_ memory: MemoryLease, guard expected: MemoryUpdateGuard) throws {
        try memoryTransaction(validating: expected.hits) { db in
            try MemorySQL.validate(memory, db: db); try MemorySQL.validateUpdate(memory, expected: expected, db: db)
            if let queue = expected.queue { try MemoryQueueSQL.finish(queue, selectedKey: memory.producerKey, outcome: "insufficient", ids: [], db: db) }
        }
    }
    func setMemoryQueueState(_ lease: MemoryQueueLease, state: MemoryQueueState, message: String) throws {
        try memoryTransaction { db in
            guard try MemoryQueueSQL.matches(lease, db: db) else { return }
            try db.execute("UPDATE memory_queue_work SET state=?,generation=?,attempt=NULL,message=? WHERE sequence=?", bindings: [state.rawValue, UUID().uuidString, message, String(lease.job.sequence)])
        }
    }
    func cancelMemoryQueue(_ sequence: Int64, run: String? = nil) throws {
        try memoryTransaction { db in try MemoryQueueSQL.requireRun(run, db: db); try db.execute("UPDATE memory_queue_work SET state='cancelled',generation=?,attempt=NULL,message='Отменено пользователем.' WHERE sequence=? AND cursor<total AND state NOT IN ('completed','insufficient')", bindings: [UUID().uuidString, String(sequence)]) }
    }
    func retryMemoryQueue(_ sequence: Int64, run: String? = nil) throws {
        try memoryTransaction { db in try MemoryQueueSQL.requireRun(run, db: db); try db.execute("UPDATE memory_queue_work SET state=CASE WHEN cursor>0 THEN 'partial' ELSE 'queued' END,generation=?,attempt=NULL,message='' WHERE sequence=? AND state NOT IN ('completed','insufficient')", bindings: [UUID().uuidString, String(sequence)]) }
    }
    func pauseMemoryQueueForConsent(_ lease: MemoryQueueLease) throws {
        try memoryTransaction { db in try MemoryQueueSQL.validate(lease, db: db); try db.execute("UPDATE memory_queue_work SET state='needsConsent',message='Нужно разовое разрешение на точный batch.' WHERE sequence=?", bindings: [String(lease.job.sequence)]) }
    }
    func resumeMemoryQueueConsent(_ lease: MemoryQueueLease) throws {
        try memoryTransaction { db in try MemoryQueueSQL.validate(lease, db: db); try db.execute("UPDATE memory_queue_work SET state='running',message='' WHERE sequence=?", bindings: [String(lease.job.sequence)]) }
    }
}

nonisolated enum MemoryQueueSQL {
    static func requireRun(_ run: String?, db: ProjectDatabase) throws {
        if let run { guard try db.rows("SELECT generation FROM memory_queue_runtime WHERE slot=1").first?.first == run else { throw MemoryQueueError.stale } }
    }
    static let select = "SELECT sequence,project_id,source_key,source,input,generation,state,cursor,total,COALESCE(selected_key,''),message,cycle FROM memory_queue_work"
    static func job(_ row: [String]) throws -> MemoryQueueJob {
        guard row.count == 12, let sequence = Int64(row[0]), let project = UUID(uuidString: row[1]), let state = MemoryQueueState(rawValue: row[6]), let cursor = Int(row[7]), let total = Int(row[8]) else { throw MemoryQueueError.stale }
        return .init(sequence: sequence, projectID: project, source: try MemoryEncoding.decode(EmbeddingSourceKey.self, row[3]), input: row[4], cycle: row[11], generation: row[5], state: state, completedChunks: cursor, totalChunks: total, selectedInputKey: row[9].isEmpty ? nil : row[9], message: row[10])
    }
    static func manualVersion(_ id: UUID, db: ProjectDatabase) throws -> Int64 {
        Int64(try db.rows("SELECT COALESCE(MAX(sequence),0) FROM memory_events WHERE project_id=? AND json_extract(body,'$.origin')='manual'", bindings: [id.uuidString]).first?.first ?? "") ?? 0
    }
    static func input(project: UUID, source: EmbeddingSourceKey, model: String, contract: String, identity: String, db: ProjectDatabase) throws -> (hash: String, state: MemoryQueueState, total: Int, message: String) {
        let row = try db.rows("SELECT e.generation,s.revision,j.generation,j.model_id,j.state FROM embedding_sources s JOIN embedding_source_epochs e ON e.source_key=s.source_key JOIN embedding_jobs j ON j.source_key=s.source_key WHERE s.source_key=?", bindings: [source.rawValue]).first ?? []
        let owners = try MemorySQL.currentOwners(source, db: db)
        let projects = try owners.union([project]).sorted { $0.uuidString < $1.uuidString }.map { try MemorySQL.project($0, db: db) }
        let modelRows = try db.rows("SELECT model_id,dimensions FROM embedding_active_model WHERE slot=1")
        let epoch = try db.rows("SELECT generation FROM knowledge_model_epoch WHERE slot=1")
        let total = Int(try db.rows("SELECT COUNT(*) FROM embedding_chunks WHERE source_key=?", bindings: [source.rawValue]).first?.first ?? "") ?? 0
        let known = projects.compactMap { $0 }
        let manual = try manualVersion(project, db: db)
        struct Input: Encodable { let project: UUID; let source: EmbeddingSourceKey; let row: [String]; let owners: [UUID]; let projects: [KnowledgeProject]; let indexModel: [[String]]; let epoch: [[String]]; let generator: String; let extractor: String; let file: String; let manual: Int64; let chunks: Int }
        let value = Input(project: project, source: source, row: row, owners: owners.sorted { $0.uuidString < $1.uuidString }, projects: known, indexModel: modelRows, epoch: epoch, generator: model, extractor: contract, file: identity, manual: manual, chunks: total)
        let hash = MemoryEncoding.hash(try MemoryEncoding.encode(value))
        if !owners.contains(project) || known.count != projects.count || row.isEmpty { return (hash,.stale,total,"Источник или владелец недоступен.") }
        if known.contains(where: { $0.cloudPolicy == .localOnly }) { return (hash,.denied,total,"Облако запрещено одним из владельцев.") }
        if row.count != 5 || row[4] != "ready" || modelRows.first?.first != row[3] || identity == "unavailable" || total == 0 { return (hash,.waiting,total,"Дождитесь актуального готового источника и индекса.") }
        if known.contains(where: { $0.cloudPolicy == .askEveryTime }) { return (hash,.needsConsent,total,"Нужно разовое разрешение на выбранный batch.") }
        return (hash,.queued,total,"")
    }
    static func dependencies(_ lease: MemoryQueueLease, db: ProjectDatabase) throws -> MemoryQueueDependencies {
        guard let body = try db.rows("SELECT dependencies FROM memory_queue_work WHERE sequence=?", bindings: [String(lease.job.sequence)]).first?.first else { throw MemoryQueueError.stale }
        return try MemoryEncoding.decode(MemoryQueueDependencies.self, body)
    }
    static func dependenciesCurrent(_ value: MemoryQueueDependencies, identities: [EmbeddingSourceKey: String]? = nil, publishing: Set<UUID> = [], db: ProjectDatabase) throws -> Bool {
        guard let memories = value.memories, let ownRetirements = value.ownRetirements else { return false }
        let closure = Set(memories)
        let allowed = closure.union(ownRetirements).union(publishing)
        let events = try closure.union(ownRetirements).sorted { $0.uuidString < $1.uuidString }.map { try MemorySQL.event($0, db: db) }
        for status in try MemorySQL.readStatus(events, db: db) {
            // Same rule as the accepted service's consumed ancestry, with an
            // exemption only for retirements actually published by this cycle.
            // Unrelated automatic heads never enter this comparison.
            if status.state != .current || !Set(status.superseded).isSubset(of: allowed) { return false }
        }
        for project in value.projects { if try MemorySQL.project(project.id, db: db) != project { return false } }
        for version in value.manual { if try manualVersion(version.projectID, db: db) != version.sequence { return false } }
        for item in value.sources {
            if try !MemorySQL.sourceCurrent(item.source, db: db) { return false }
            if try db.rows("SELECT generation,model_id,state FROM embedding_jobs WHERE source_key=?", bindings: [item.source.key.rawValue]).first != [item.jobGeneration,item.modelID,"ready"] { return false }
            if let identities, identities[item.source.key] != item.source.fileStamp { return false }
        }
        return true
    }
    static func matches(_ lease: MemoryQueueLease, db: ProjectDatabase) throws -> Bool {
        try db.rows("SELECT generation FROM memory_queue_runtime WHERE slot=1").first?.first == lease.runID && db.rows("SELECT generation,input,attempt,cursor FROM memory_queue_work WHERE sequence=?", bindings: [String(lease.job.sequence)]).first == [lease.job.generation,lease.job.input,lease.attempt,String(lease.job.completedChunks)]
    }
    static func validate(_ lease: MemoryQueueLease, publishing: Set<UUID> = [], db: ProjectDatabase) throws {
        guard try matches(lease, db: db),
              let row = try db.rows("SELECT state,generator_model,identity,generator_contract FROM memory_queue_work WHERE sequence=?", bindings: [String(lease.job.sequence)]).first,
              ["running","needsConsent"].contains(row[0]),
              try input(project: lease.job.projectID, source: lease.job.source, model: row[1], contract: row[3], identity: row[2], db: db).hash == lease.job.input,
              try dependenciesCurrent(dependencies(lease, db: db), publishing: publishing, db: db) else { throw MemoryQueueError.stale }
    }
    static func finish(_ lease: MemoryQueueLease, selectedKey: String, outcome: String, ids: [UUID], db: ProjectDatabase) throws {
        try Task.checkCancellation()
        // Journal rows/links may already have been appended in this SAME
        // transaction. Allow precisely their IDs while validating, then retain
        // only IDs which actually retire a consumed ancestor (bounded proof).
        try validate(lease, publishing: Set(ids), db: db)
        var deps = try dependencies(lease, db: db)
        var ownRetirements = Set(deps.ownRetirements ?? [])
        let closure = Set(deps.memories ?? [])
        for id in ids {
            let targets = try db.rows("SELECT target_id FROM memory_links WHERE event_id=? AND kind IN ('replaces','retracts','corrects')", bindings: [id.uuidString]).compactMap { UUID(uuidString: $0[0]) }
            if !closure.isDisjoint(with: targets) { ownRetirements.insert(id) }
        }
        guard ownRetirements.count <= 256 else { throw MemoryQueueError.budget }
        deps.ownRetirements = ownRetirements.sorted { $0.uuidString < $1.uuidString }
        guard try db.rows("SELECT state FROM memory_queue_work WHERE sequence=?", bindings: [String(lease.job.sequence)]).first?.first == "running" else { throw MemoryQueueError.stale }
        try db.execute("INSERT INTO memory_queue_batches VALUES (?,?,?,?,?,?,?,?,?)", bindings: [lease.job.projectID.uuidString,lease.job.source.rawValue,lease.job.input,lease.job.cycle,String(lease.job.completedChunks),String(lease.count),selectedKey,outcome,try MemoryEncoding.encode(ids)])
        let cursor = lease.job.completedChunks + lease.count
        let insufficient = try db.rows("SELECT 1 FROM memory_queue_batches WHERE project_id=? AND source_key=? AND input=? AND cycle=? AND outcome='insufficient' LIMIT 1", bindings: [lease.job.projectID.uuidString,lease.job.source.rawValue,lease.job.input,lease.job.cycle]).isEmpty == false
        let otherPending = Int(try db.rows("SELECT COUNT(*) FROM memory_queue_work WHERE state IN ('queued','partial','running') AND sequence!=?", bindings: [String(lease.job.sequence)]).first?.first ?? "") ?? 0
        let state: MemoryQueueState = cursor < lease.job.totalChunks ? (otherPending >= 128 ? .backpressured : .partial) : insufficient ? .insufficient : .completed
        try db.execute("UPDATE memory_queue_work SET cursor=?,state=?,generation=?,selected_key=?,dependencies=?,attempt=NULL,message=? WHERE sequence=?", bindings: [String(cursor),state.rawValue,UUID().uuidString,selectedKey,try MemoryEncoding.encode(deps),insufficient ? "Часть фрагментов не дала достаточных оснований; факты не выдуманы." : "",String(lease.job.sequence)])
        try Task.checkCancellation()
    }
}
