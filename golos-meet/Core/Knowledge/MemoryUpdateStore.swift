import Foundation

extension ProjectStore {
    func validateMemoryUpdate(_ lease: MemoryLease, guard expected: MemoryUpdateGuard) throws {
        try memoryTransaction(validating: expected.hits) { db in
            try MemorySQL.validate(lease, db: db)
            try MemorySQL.validateUpdate(lease, expected: expected, db: db)
        }
    }
    func existingMemoryUpdate(_ lease: MemoryLease, guard expected: MemoryUpdateGuard) throws -> MemoryPublication? {
        try memoryTransaction(validating: expected.hits) { db in
            try MemorySQL.validate(lease, db: db)
            try MemorySQL.validateUpdate(lease, expected: expected, db: db)
            guard let row = try db.rows("SELECT event_ids FROM memory_batches WHERE project_id=? AND producer_key=? AND fingerprint=?", bindings: [lease.projectID.uuidString, lease.producerKey, lease.fingerprint]).first else { return nil }
            return .unchanged(try MemoryEncoding.decode([UUID].self, row[0]))
        }
    }
}

extension MemorySQL {
    static func updateCheckpoint(_ lease: MemoryLease, db: ProjectDatabase) throws -> MemoryUpdateCheckpoint {
        let projects = try lease.ownerProjectIDs.map { id in
            guard let value = try project(id, db: db) else { throw MemoryUpdateError.stale }; return value
        }
        var closure: [UUID: MemoryEvent] = [:], queue = lease.parents
        while let event = queue.popLast() {
            guard closure[event.id] == nil else { continue }
            guard closure.count < 256 else { throw ProjectMemoryError.limited }
            closure[event.id] = event
            queue += try event.parentEventIDs.map { try self.event($0, db: db) }
        }
        let all = closure.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let allStatuses = try readStatus(all, db: db)
        let closureIDs = Set(closure.keys)
        for (event, status) in zip(all, allStatuses) {
            // A correction may consume the immutable event it supersedes.
            // A retirement outside the consumed chain makes derived text stale.
            guard status.state == .current, Set(status.superseded).isSubset(of: closureIDs),
                  Set(event.ownerProjectIDs).isSubset(of: Set(lease.ownerProjectIDs)) else { throw MemoryUpdateError.stale }
        }
        let statuses = try readStatus(lease.parents, db: db)
        for (parent, status) in zip(lease.parents, statuses) {
            let slot = try MemoryEncoding.slot(parent.statement)
            guard parent.action == .assertion, status.state == .current, status.superseded.isEmpty, status.conflicts.isEmpty,
                  try db.rows("SELECT event_id FROM memory_head_versions WHERE project_id=? AND slot=? ORDER BY sequence DESC LIMIT 1", bindings: [parent.projectID.uuidString, slot]).first?.first == parent.id.uuidString else { throw MemoryUpdateError.stale }
        }
        let versions = try Set(all.map(\.projectID)).sorted { $0.uuidString < $1.uuidString }.map { id in
            guard let row = try db.rows("SELECT generation,revision FROM memory_state WHERE project_id=?", bindings: [id.uuidString]).first,
                  let revision = Int(row[1]) else { throw MemoryUpdateError.stale }
            return MemoryUpdateVersion(projectID: id, generation: row[0], revision: revision)
        }
        return .init(projects: projects, parentVersions: versions)
    }
    static func validateUpdate(_ lease: MemoryLease, expected: MemoryUpdateGuard, db: ProjectDatabase) throws {
        guard !expected.hits.isEmpty, expected.hits.count == lease.sources.count,
              expected.hits.allSatisfy({ $0.matchedMeaning && $0.model.model != nil && $0.source.job.state == .ready }),
              try sources(expected.hits.map { try MemorySourceReference(hit: $0) }) == lease.sources,
              try updateCheckpoint(lease, db: db) == expected.checkpoint else { throw MemoryUpdateError.stale }
    }
}

/// Only the service's batch identity changes after the bounded payload is built.
/// Keep the original provenance fingerprint, generation/revision and policy CAS;
/// no extra begin(), epoch change, table migration or legacy caller change.
extension MemoryLease {
    func bindingUpdateInput(_ producerKey: String) -> MemoryLease {
        .init(projectID: projectID, producerKey: producerKey, fingerprint: fingerprint,
              generation: generation, baseRevision: baseRevision, assignmentEpoch: assignmentEpoch,
              origin: origin, manualTargetID: manualTargetID, parents: parents,
              sources: sources, ownerProjectIDs: ownerProjectIDs)
    }
}
