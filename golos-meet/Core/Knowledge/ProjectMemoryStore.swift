import Foundation

extension ProjectStore {
    func beginMemory(projectID: UUID, producerKey: String, hits: [KnowledgeSearchHit], parentIDs: [UUID],
                     correcting targetID: UUID? = nil) throws -> MemoryLease {
        guard !producerKey.isEmpty, producerKey.count <= 256, !producerKey.contains("\0"),
              hits.count <= 32, parentIDs.count <= 32 else { throw ProjectMemoryError.invalid }
        return try memoryTransaction(validating: hits) { db in
            guard try !db.rows("SELECT id FROM projects WHERE id=?", bindings: [projectID.uuidString]).isEmpty,
                  hits.allSatisfy({ $0.source.owners.contains(projectID) }) else { throw ProjectMemoryError.invalid }
            let ids = Set(parentIDs + (targetID.map { [$0] } ?? []))
            let parents = try ids.sorted { $0.uuidString < $1.uuidString }.map { try MemorySQL.event($0, db: db) }
            if let targetID {
                guard parents.first(where: { $0.id == targetID })?.projectID == projectID else { throw ProjectMemoryError.invalid }
            }
            let sources = try MemorySQL.sources(hits.map { try MemorySourceReference(hit: $0) } + parents.flatMap(\.sources))
            guard !sources.isEmpty, sources.count <= 128,
                  sources.reduce(0, { $0 + $1.chunk.text.count }) <= 128_000 else { throw ProjectMemoryError.limited }
            guard try sources.allSatisfy({ try MemorySQL.sourceCurrent($0, db: db) }) else { throw ProjectMemoryError.stale }
            let owners = Set(sources.flatMap(\.ownerProjectIDs)).union(parents.flatMap(\.ownerProjectIDs)).union([projectID])
            guard try owners.allSatisfy({ try MemorySQL.project($0, db: db) != nil }) else { throw ProjectMemoryError.unavailable }
            let sortedOwners = owners.sorted { $0.uuidString < $1.uuidString }
            let origin: MemoryOrigin = targetID == nil ? .model : .manual
            struct Input: Encodable { let sources: [MemorySourceReference]; let parents: [UUID]; let origin: MemoryOrigin; let target: UUID? }
            let fingerprint = MemoryEncoding.hash(try MemoryEncoding.encode(Input(sources: sources,
                parents: parents.map(\.id), origin: origin, target: targetID)))
            try db.execute("INSERT INTO memory_state VALUES (?, ?, 0) ON CONFLICT(project_id) DO NOTHING", bindings: [projectID.uuidString, UUID().uuidString])
            let generation = UUID().uuidString
            try db.execute("UPDATE memory_state SET generation=? WHERE project_id=?", bindings: [generation, projectID.uuidString])
            guard let row = try db.rows("SELECT revision FROM memory_state WHERE project_id=?", bindings: [projectID.uuidString]).first,
                  let revision = Int(row[0]), let epoch = try db.rows("SELECT generation FROM assignment_epoch WHERE slot=1").first?.first else { throw ProjectMemoryError.invalid }
            return .init(projectID: projectID, producerKey: producerKey, fingerprint: fingerprint,
                generation: generation, baseRevision: revision, assignmentEpoch: epoch, origin: origin,
                manualTargetID: targetID, parents: parents, sources: sources, ownerProjectIDs: sortedOwners)
        }
    }

    func validateMemoryLease(_ lease: MemoryLease) throws {
        try memoryTransaction { db in try MemorySQL.validate(lease, db: db) }
    }

    func publishMemory(_ drafts: [MemoryDraft], lease: MemoryLease, extractedAt: Date) throws -> MemoryPublication {
        guard !drafts.isEmpty, drafts.count <= 32, extractedAt.timeIntervalSince1970.isFinite,
              lease.origin != .manual || drafts.count == 1 else { throw ProjectMemoryError.invalid }
        return try memoryTransaction { db in
            try Task.checkCancellation()
            try MemorySQL.validate(lease, db: db)
            let batchBindings = [lease.projectID.uuidString, lease.producerKey, lease.fingerprint]
            if let row = try db.rows("SELECT event_ids FROM memory_batches WHERE project_id=? AND producer_key=? AND fingerprint=?", bindings: batchBindings).first {
                return .unchanged(try MemoryEncoding.decode([UUID].self, row[0]))
            }
            var eventIDs: [UUID] = []
            for draft in drafts {
                try Task.checkCancellation()
                try MemorySQL.validate(draft, lease: lease)
                let slot = try MemoryEncoding.slot(draft.statement)
                let supersessions = draft.links + (lease.manualTargetID.map { [MemoryExplicitLink(targetID: $0, kind: .corrects)] } ?? [])
                for link in supersessions {
                    let target = try MemorySQL.event(link.targetID, db: db)
                    guard lease.origin == .manual || target.origin != .manual else { throw ProjectMemoryError.invalid }
                    guard [.replaces, .retracts, .corrects].contains(link.kind), target.projectID == lease.projectID,
                          try MemoryEncoding.slot(target.statement) == slot,
                          link.kind != .corrects || link.targetID == lease.manualTargetID else { throw ProjectMemoryError.invalid }
                }
                let active = try db.rows("SELECT e.body FROM memory_events e WHERE e.project_id=? AND e.slot=? AND NOT EXISTS (SELECT 1 FROM memory_links l WHERE l.target_id=e.id AND l.kind IN ('replaces','retracts','corrects')) ORDER BY e.sequence LIMIT 257", bindings: [lease.projectID.uuidString, slot])
                guard active.count <= 256 else { throw ProjectMemoryError.limited }
                let event = MemoryEvent(id: UUID(), projectID: lease.projectID, origin: lease.origin, action: draft.action,
                    statement: draft.statement, evidenceChunkIDs: draft.evidenceChunkIDs.sorted(),
                    parentEventIDs: lease.parents.map(\.id), sources: lease.sources,
                    ownerProjectIDs: lease.ownerProjectIDs, decisionDate: draft.decisionDate, extractedAt: extractedAt)
                try db.execute("INSERT INTO memory_events(id, project_id, slot, body) VALUES (?, ?, ?, ?)",
                    bindings: [event.id.uuidString, lease.projectID.uuidString, slot, try MemoryEncoding.encode(event)])
                for parent in lease.parents { try MemorySQL.link(event.id, parent.id, .derivedFrom, db: db) }
                for link in supersessions { try MemorySQL.link(event.id, link.targetID, link.kind, db: db) }
                let retired = Set(supersessions.map(\.targetID))
                for row in active {
                    let old = try MemoryEncoding.decode(MemoryEvent.self, row[0])
                    if !retired.contains(old.id) { try MemorySQL.link(event.id, old.id, MemoryEncoding.relation(event.statement, old.statement), db: db) }
                }
                let manualHead = try db.rows("SELECT manual FROM memory_head_versions WHERE project_id=? AND slot=? ORDER BY sequence DESC LIMIT 1", bindings: [lease.projectID.uuidString, slot]).first?.first == "1"
                // Automatic publications append evidence but never replace a
                // selected manual correction, including after restart/reindex.
                if lease.origin == .manual || !manualHead {
                    try db.execute("INSERT INTO memory_head_versions(project_id, slot, event_id, manual) VALUES (?, ?, ?, ?)",
                        bindings: [lease.projectID.uuidString, slot, event.id.uuidString, lease.origin == .manual ? "1" : "0"])
                }
                eventIDs.append(event.id)
            }
            try db.execute("INSERT INTO memory_batches VALUES (?, ?, ?, ?)", bindings: batchBindings + [try MemoryEncoding.encode(eventIDs)])
            try db.execute("UPDATE memory_state SET revision=revision+1, generation=? WHERE project_id=?", bindings: [UUID().uuidString, lease.projectID.uuidString])
            try Task.checkCancellation()
            return .inserted(eventIDs)
        }
    }

    func memoryEvent(_ id: UUID) throws -> MemoryEvent { try memoryTransaction { try MemorySQL.event(id, db: $0) } }

    func memoryHistoryRows(projectID: UUID, before: Int64?, limit: Int) throws -> [(Int64, MemoryEvent)] {
        guard (1...200).contains(limit) else { throw ProjectMemoryError.invalid }
        return try memoryTransaction { db in
            try db.rows("SELECT sequence, body FROM memory_events WHERE project_id=? AND sequence<? ORDER BY sequence DESC LIMIT ?",
                bindings: [projectID.uuidString, String(before ?? Int64.max), String(limit + 1)]).map { row in
                    guard let seq = Int64(row[0]) else { throw ProjectMemoryError.invalid }
                    return (seq, try MemoryEncoding.decode(MemoryEvent.self, row[1]))
                }
        }
    }
    func memoryHeadRows(projectID: UUID, limit: Int) throws -> [(Int64, Int64, MemoryEvent, Bool)] {
        guard (1...200).contains(limit) else { throw ProjectMemoryError.invalid }
        return try memoryTransaction { db in
            try db.rows("SELECT h.sequence, e.sequence, e.body, h.manual FROM memory_head_versions h JOIN memory_events e ON e.id=h.event_id WHERE h.project_id=? AND NOT EXISTS (SELECT 1 FROM memory_head_versions newer WHERE newer.project_id=h.project_id AND newer.slot=h.slot AND newer.sequence>h.sequence) ORDER BY h.sequence DESC LIMIT ?", bindings: [projectID.uuidString, String(limit + 1)]).map {
                guard let seq = Int64($0[0]), let eventSeq = Int64($0[1]) else { throw ProjectMemoryError.invalid }
                return (seq, eventSeq, try MemoryEncoding.decode(MemoryEvent.self, $0[2]), $0[3] == "1")
            }
        }
    }
    func memoryReadStatus(_ events: [MemoryEvent]) throws -> [(state: MemoryEvidenceState, superseded: [UUID], conflicts: [UUID])] {
        try memoryTransaction { db in try MemorySQL.readStatus(events, db: db) }
    }
    /// Fence a selection replaced while the caller was validating files.
    /// Selection identity and source/owner status come from one final snapshot.
    func memoryHeadStatus(projectID: UUID, expectedVersions: [Int64], events: [MemoryEvent], limit: Int) throws -> [(state: MemoryEvidenceState, superseded: [UUID], conflicts: [UUID])] {
        guard (1...200).contains(limit) else { throw ProjectMemoryError.invalid }
        return try memoryTransaction { db in
            let versions = try db.rows("SELECT h.sequence FROM memory_head_versions h WHERE h.project_id=? AND NOT EXISTS (SELECT 1 FROM memory_head_versions newer WHERE newer.project_id=h.project_id AND newer.slot=h.slot AND newer.sequence>h.sequence) ORDER BY h.sequence DESC LIMIT ?", bindings: [projectID.uuidString, String(limit + 1)]).map { row in
                guard let value = Int64(row[0]) else { throw ProjectMemoryError.invalid }; return value
            }
            guard versions == expectedVersions else { throw ProjectMemoryError.stale }
            return try MemorySQL.readStatus(events, db: db)
        }
    }
    func memoryClosure(_ id: UUID) throws -> (events: [MemoryEvent], sources: [MemorySourceReference], owners: Set<UUID>, projects: [KnowledgeProject], states: [MemoryEvidenceState]) {
        try memoryTransaction { db in
            var visited: Set<UUID> = [], queue = [id], events: [MemoryEvent] = []
            while let next = queue.popLast() {
                guard visited.insert(next).inserted else { continue }
                guard visited.count <= 256 else { throw ProjectMemoryError.limited }
                let event = try MemorySQL.event(next, db: db); events.append(event); queue += event.parentEventIDs
            }
            let sources = try MemorySQL.sources(events.flatMap(\.sources))
            var owners = Set(events.flatMap(\.ownerProjectIDs))
            for source in sources { owners.formUnion(try MemorySQL.currentOwners(source.key, db: db)) }
            let projects = try owners.sorted { $0.uuidString < $1.uuidString }.compactMap { try MemorySQL.project($0, db: db) }
            return (events.sorted { $0.id.uuidString < $1.id.uuidString }, sources, owners, projects, try MemorySQL.readStatus(events, db: db).map(\.state))
        }
    }
}

/// No connection escapes these synchronous store transactions.
nonisolated enum MemorySQL {
    static func readStatus(_ events: [MemoryEvent], db: ProjectDatabase) throws -> [(state: MemoryEvidenceState, superseded: [UUID], conflicts: [UUID])] {
            try events.map { event in
                let known = try event.ownerProjectIDs.allSatisfy { try project($0, db: db) != nil }
                let current = try event.sources.allSatisfy { try sourceCurrent($0, db: db) }
                let superseded = try db.rows("SELECT event_id FROM memory_links WHERE target_id=? AND kind IN ('replaces','retracts','corrects') ORDER BY event_id", bindings: [event.id.uuidString]).compactMap { UUID(uuidString: $0[0]) }
                // A superseded conflict endpoint is historical, not an active
                // contradictory candidate. The relation itself is retained.
                let conflicts = try db.rows("SELECT CASE WHEN l.event_id=? THEN l.target_id ELSE l.event_id END AS other FROM memory_links l WHERE l.kind='conflicts' AND (l.event_id=? OR l.target_id=?) AND NOT EXISTS (SELECT 1 FROM memory_links r WHERE r.target_id=other AND r.kind IN ('replaces','retracts','corrects')) ORDER BY other", bindings: Array(repeating: event.id.uuidString, count: 3)).compactMap { UUID(uuidString: $0[0]) }
                return (known ? (current ? .current : .stale) : .unconfirmed, superseded, conflicts)
            }
    }
    static func event(_ id: UUID, db: ProjectDatabase) throws -> MemoryEvent {
        guard let row = try db.rows("SELECT body FROM memory_events WHERE id=?", bindings: [id.uuidString]).first else { throw ProjectMemoryError.missing }
        let value = try MemoryEncoding.decode(MemoryEvent.self, row[0])
        guard value.id == id else { throw ProjectMemoryError.invalid }
        return value
    }
    static func project(_ id: UUID, db: ProjectDatabase) throws -> KnowledgeProject? {
        guard let row = try db.rows("SELECT name, parent_id, cloud_policy FROM projects WHERE id=?", bindings: [id.uuidString]).first,
              let policy = ProjectCloudPolicy(rawValue: row[2]) else { return nil }
        return .init(id: id, name: row[0], parentID: UUID(uuidString: row[1]), cloudPolicy: policy)
    }
    static func currentOwners(_ key: EmbeddingSourceKey, db: ProjectDatabase) throws -> Set<UUID> {
        let sql = key.kind == .meeting ? "SELECT project_id FROM meeting_projects WHERE meeting_id=?" : "SELECT project_id FROM document_projects WHERE document_id=?"
        return try Set(db.rows(sql, bindings: [key.externalID]).map {
            guard let id = UUID(uuidString: $0[0]) else { throw ProjectMemoryError.invalid }; return id
        })
    }
    static func sourceCurrent(_ source: MemorySourceReference, db: ProjectDatabase) throws -> Bool {
        guard let row = try db.rows("SELECT e.generation,s.revision FROM embedding_source_epochs e JOIN embedding_sources s ON s.source_key=e.source_key WHERE s.source_key=?", bindings: [source.key.rawValue]).first,
              row == [source.generation, source.revision],
              try currentOwners(source.key, db: db) == Set(source.ownerProjectIDs),
              let chunk = try db.rows("SELECT source_id,revision,ordinal,text,location FROM embedding_chunks WHERE id=? AND source_key=?", bindings: [source.chunk.id, source.key.rawValue]).first,
              UUID(uuidString: chunk[0]) == source.chunk.sourceID, chunk[1] == source.chunk.revision,
              Int(chunk[2]) == source.chunk.ordinal, chunk[3] == source.chunk.text,
              try MemoryEncodingLocation.decode(chunk[4]) == source.chunk.location else { return false }
        if let copy = source.document {
            guard source.key.kind == .document,
                  let row = try db.rows("SELECT d.current_version,v.content_hash,v.relative_path FROM documents d JOIN document_versions v ON v.id=d.current_version WHERE d.id=?", bindings: [source.key.externalID]).first,
                  row == [copy.versionID.uuidString, copy.contentHash, copy.relativePath] else { return false }
        } else if source.key.kind != .meeting { return false }
        return true
    }
    static func sources(_ values: [MemorySourceReference]) throws -> [MemorySourceReference] {
        var byID: [String: MemorySourceReference] = [:]
        for source in values {
            if let old = byID[source.identity], old != source { throw ProjectMemoryError.stale }
            byID[source.identity] = source
        }
        return byID.keys.sorted().compactMap { byID[$0] }
    }
    static func validate(_ lease: MemoryLease, db: ProjectDatabase) throws {
        guard try project(lease.projectID, db: db) != nil,
              try db.rows("SELECT generation,revision FROM memory_state WHERE project_id=?", bindings: [lease.projectID.uuidString]).first == [lease.generation, String(lease.baseRevision)],
              try db.rows("SELECT generation FROM assignment_epoch WHERE slot=1").first?.first == lease.assignmentEpoch,
              try lease.sources.allSatisfy({ try sourceCurrent($0, db: db) }),
              try lease.ownerProjectIDs.allSatisfy({ try project($0, db: db) != nil }) else { throw ProjectMemoryError.stale }
    }
    static func validate(_ draft: MemoryDraft, lease: MemoryLease) throws {
        let value = draft.statement
        guard !value.subject.isEmpty, value.subject.count <= 256, !value.subject.contains("\0"),
              !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.text.count <= 16_000,
              !value.text.contains("\0"), value.conditions.count <= 16,
              value.conditions.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 256 && $0.value.count <= 512 && !$0.key.contains("\0") && !$0.value.contains("\0") }),
              !draft.evidenceChunkIDs.isEmpty, draft.evidenceChunkIDs.isSubset(of: Set(lease.sources.map { $0.chunk.id })),
              draft.links.count <= 32, draft.decisionDate?.timeIntervalSince1970.isFinite != false else { throw ProjectMemoryError.invalid }
        if draft.action == .retraction {
            guard value.deadline == nil, draft.links.contains(where: { $0.kind == .retracts }) else { throw ProjectMemoryError.invalid }
        } else if value.kind == .deadline {
            guard let range = value.deadline, range.earliest.timeIntervalSince1970.isFinite,
                  range.latest.timeIntervalSince1970.isFinite, range.earliest <= range.latest else { throw ProjectMemoryError.invalid }
        } else if value.deadline != nil { throw ProjectMemoryError.invalid }
        if let targetID = lease.manualTargetID {
            guard let target = lease.parents.first(where: { $0.id == targetID }),
                  try MemoryEncoding.slot(target.statement) == MemoryEncoding.slot(value) else { throw ProjectMemoryError.invalid }
        }
    }
    static func link(_ from: UUID, _ to: UUID, _ kind: MemoryLinkKind, db: ProjectDatabase) throws {
        try db.execute("INSERT OR IGNORE INTO memory_links VALUES (?, ?, ?)", bindings: [from.uuidString, to.uuidString, kind.rawValue])
    }
}
private nonisolated enum MemoryEncodingLocation {
    static func decode(_ value: String) throws -> KnowledgeLocation { try JSONDecoder().decode(KnowledgeLocation.self, from: Data(value.utf8)) }
}
