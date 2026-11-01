import Foundation

/// Local storage contract only. No model/extractor, default paths, production
/// wiring or network client. Structured facts are assertions supplied by a
/// future extractor/user, never an assertion that meaning was verified here.
actor ProjectMemoryHistoryService {
    private let store: ProjectStore
    private let reader: KnowledgeSearchSourceReader
    init(store: ProjectStore, meetingsRoot: URL, documentsRoot: URL) {
        self.store = store
        reader = KnowledgeSearchSourceReader(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
    }
    func begin(projectID: UUID, producerKey: String, hits: [KnowledgeSearchHit],
               parentEventIDs: [UUID] = []) async throws -> MemoryLease {
        let lease = try await store.beginMemory(projectID: projectID, producerKey: producerKey, hits: hits, parentIDs: parentEventIDs)
        try await validateFiles(lease.sources)
        try Task.checkCancellation()
        try await store.validateMemoryLease(lease)
        return lease
    }
    /// An explicit user intent ID makes replay of the same correction idempotent.
    /// The original event is always a parent; neither it nor its owners can be
    /// dropped by replacing the display text or selecting new supporting labels.
    func beginCorrection(eventID: UUID, intentID: UUID) async throws -> MemoryLease {
        let event = try await store.memoryEvent(eventID)
        let lease = try await store.beginMemory(projectID: event.projectID, producerKey: "manual:" + intentID.uuidString,
                                                hits: [], parentIDs: [], correcting: eventID)
        try await validateFiles(lease.sources)
        try await store.validateMemoryLease(lease)
        return lease
    }
    func publish(_ drafts: [MemoryDraft], lease: MemoryLease, extractedAt: Date = Date()) async throws -> MemoryPublication {
        try await validateFiles(lease.sources)
        try Task.checkCancellation()
        // Final SQLite CAS/source/owner check and append in ONE transaction.
        // Files and SQLite are not atomic; mutations after the last file check
        // cannot be prevented by this local contract. Every read checks again.
        return try await store.publishMemory(drafts, lease: lease, extractedAt: extractedAt)
    }
    func history(projectID: UUID, beforeSequence: Int64? = nil, limit: Int = 100) async throws -> MemoryHistoryPage {
        let fetched = try await store.memoryHistoryRows(projectID: projectID, before: beforeSequence, limit: limit)
        let rows = Array(fetched.prefix(limit))
        let entries = try await checkedEntries(rows)
        return .init(entries: entries, nextBeforeSequence: fetched.count > limit ? rows.last?.0 : nil)
    }
    func heads(projectID: UUID, limit: Int = 100) async throws -> MemoryHeadsPage {
        let fetched = try await store.memoryHeadRows(projectID: projectID, limit: limit)
        let rows = Array(fetched.prefix(limit))
        let events = rows.map { $0.2 }
        let unavailable = try await unavailableSources(events.flatMap(\.sources))
        let statuses = try await store.memoryHeadStatus(projectID: projectID,
            expectedVersions: fetched.map { $0.0 }, events: events, limit: limit)
        let heads = zip(rows, statuses).map { row, status in
            let state = Self.state(status.state, sources: row.2.sources, unavailable: unavailable)
            let entry = MemoryHistoryEntry(sequence: row.1, event: row.2, evidenceState: state, supersededBy: status.superseded)
            return MemoryHead(version: row.0, entry: entry, manualSelection: row.3, conflictingEventIDs: status.conflicts)
        }
        return .init(heads: heads, limited: fetched.count > limit)
    }
    func provenance(eventID: UUID) async throws -> MemoryProvenance {
        let first = try await store.memoryClosure(eventID)
        let unavailable = try await unavailableSources(first.sources)
        // Re-read owners/policies/availability together AFTER filesystem awaits.
        // This is a local proof snapshot, not network authorization for #37.
        let current = try await store.memoryClosure(eventID)
        let missing = current.owners.subtracting(current.projects.map(\.id))
        let state: MemoryEvidenceState = !missing.isEmpty || current.states.contains(.unconfirmed) || !unavailable.isEmpty
            ? .unconfirmed : current.states.contains(.stale) ? .stale : .current
        return .init(rootEventID: eventID, events: current.events, sources: current.sources,
                     ownerProjectIDs: current.owners, knownProjects: current.projects,
                     missingOwnerProjectIDs: missing, evidenceState: state)
    }
    private func checkedEntries(_ rows: [(Int64, MemoryEvent)]) async throws -> [MemoryHistoryEntry] {
        let events = rows.map(\.1)
        let unavailable = try await unavailableSources(events.flatMap(\.sources))
        let statuses = try await store.memoryReadStatus(events)
        return zip(rows, statuses).map { row, status in
            .init(sequence: row.0, event: row.1, evidenceState: Self.state(status.state, sources: row.1.sources, unavailable: unavailable), supersededBy: status.superseded)
        }
    }
    private static func state(_ databaseState: MemoryEvidenceState, sources: [MemorySourceReference], unavailable: Set<String>) -> MemoryEvidenceState {
        databaseState == .current && sources.contains(where: { unavailable.contains($0.identity) }) ? .unconfirmed : databaseState
    }
    private func validateFiles(_ sources: [MemorySourceReference]) async throws {
        if try await !unavailableSources(sources).isEmpty { throw ProjectMemoryError.unavailable }
    }
    private func unavailableSources(_ sources: [MemorySourceReference]) async throws -> Set<String> {
        let sources = try MemorySQL.sources(sources)
        var unavailable: Set<String> = []
        for source in sources {
            try Task.checkCancellation()
            do { _ = try await reader.read(source.readerHit(), includePDF: false) }
            catch is CancellationError { throw CancellationError() }
            catch { unavailable.insert(source.identity) }
        }
        for source in sources where !unavailable.contains(source.identity) {
            try Task.checkCancellation()
            do {
                guard try await reader.identity(source.readerHit().source) == source.fileStamp else {
                    unavailable.insert(source.identity); continue
                }
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable.insert(source.identity) }
        }
        return unavailable
    }
}
