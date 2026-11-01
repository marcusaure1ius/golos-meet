import Foundation

extension ProjectStore {
    /// Read-only UI fence. Conservative across projects; never re-enqueues work.
    func memoryPanelStamp() throws -> String {
        try memoryTransaction { db in
            let statements = [
                "SELECT id,name,COALESCE(parent_id,''),cloud_policy FROM projects ORDER BY id",
                "SELECT generation FROM assignment_epoch WHERE slot=1",
                "SELECT generation FROM knowledge_model_epoch WHERE slot=1",
                "SELECT source_key,generation FROM embedding_source_epochs ORDER BY source_key",
                "SELECT source_key,generation,model_id,state FROM embedding_jobs ORDER BY source_key",
                "SELECT project_id,generation,revision FROM memory_state ORDER BY project_id",
                "SELECT COALESCE(MAX(sequence),0) FROM memory_events",
                "SELECT COALESCE(MAX(sequence),0) FROM memory_head_versions"
            ]
            return try MemoryEncoding.hash(MemoryEncoding.encode(statements.map { try db.rows($0) }))
        }
    }
    func validateMemoryPanelSource(_ source: MemorySourceReference) throws {
        try memoryTransaction { db in
            guard try MemorySQL.sourceCurrent(source,db:db) else { throw KnowledgeSearchError.sourceChanged }
        }
    }
    /// The local history reader checks full raw provenance/files. This adds the
    /// accepted service's ancestry retirement rule without reserving a lease or
    /// incrementing memory generation merely because a panel is rendered.
    func memoryPanelAncestryState(_ id: UUID) throws -> MemoryEvidenceState {
        try memoryTransaction { db in
            var events: [UUID:MemoryEvent] = [:], pending = [id]
            while let next = pending.popLast() {
                guard events[next] == nil else { continue }
                guard events.count < 256 else { throw ProjectMemoryError.limited }
                let event = try MemorySQL.event(next,db:db)
                events[next] = event; pending += event.parentEventIDs
            }
            let allowed = Set(events.keys)
            for state in try MemorySQL.readStatus(Array(events.values),db:db) {
                if state.state == .unconfirmed { return .unconfirmed }
                if state.state != .current || !Set(state.superseded).isSubset(of:allowed) { return .stale }
            }
            return .current
        }
    }
}
