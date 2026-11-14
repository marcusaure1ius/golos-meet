import Foundation
import CryptoKit

/// Stable inputs exclude auto ownership/results: publishing an automatic link
/// cannot train or continuously reschedule itself. File stamps detect changes
/// before FSEvents. Content bytes are verified by prepare/commit/open separately.
actor MeetingAssignmentInputReader {
    private let store: ProjectStore
    private let reader: KnowledgeSearchSourceReader
    init(store: ProjectStore, meetingsRoot: URL, documentsRoot: URL) {
        self.store = store
        reader = KnowledgeSearchSourceReader(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
    }
    func capture(additionalIDs: Set<String> = []) async throws -> MeetingAssignmentInputs {
        let checkpoint = try await store.meetingAssignmentCheckpoint()
        let sources = Dictionary(uniqueKeysWithValues: checkpoint.sources.map { ($0.key, $0) })
        var stamps: [EmbeddingSourceKey: String] = [:]
        let ids = additionalIDs.union(checkpoint.decisions.keys).union(checkpoint.sources.filter { $0.key.kind == .meeting }.map { $0.key.externalID })
        let keys = checkpoint.contextKeys.union(ids.map { EmbeddingSourceKey(kind: .meeting, externalID: $0) })
        for key in keys {
            try Task.checkCancellation()
            if key.kind == .meeting, checkpoint.decisions[key.externalID]?.origin == .manual, !checkpoint.contextKeys.contains(key) { continue }
            if let source = sources[key] { stamps[key] = (try? await reader.identity(source)) ?? "unavailable" }
        }
        func signature(_ key: EmbeddingSourceKey, context: Bool) -> [String] {
            guard let source = sources[key] else { return [key.rawValue, "absent"] }
            var values = [key.rawValue, source.observation.generation, source.observation.revision ?? "",
                          source.job.generation, source.job.modelID, source.job.state.rawValue, stamps[key] ?? "unavailable"]
            if context {
                values += source.owners.map(\.uuidString).sorted()
                if key.kind == .meeting { values.append(checkpoint.decisions[key.externalID]?.generation ?? "") }
            }
            return values
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let projectData = try encoder.encode(checkpoint.projects)
        let common = [MeetingAssignmentPolicy.algorithm, MeetingAssignmentPolicy.lexicalProfile, checkpoint.model.generation, checkpoint.model.model?.id ?? "", String(checkpoint.model.model?.dimensions ?? 0), String(decoding: projectData, as: UTF8.self)]
        var fingerprints: [String: String] = [:]
        for id in ids {
            let key = EmbeddingSourceKey(kind: .meeting, externalID: id)
            let rows: [[String]]
            if let decision = checkpoint.decisions[id], decision.origin == .manual {
                rows = [[id, "manual", decision.generation]]
            } else {
                rows = [common, signature(key, context: false)] + checkpoint.contextKeys.subtracting([key]).sorted { $0.rawValue < $1.rawValue }.map { signature($0, context: true) }
            }
            fingerprints[id] = SHA256.hash(data: try encoder.encode(rows)).map { String(format: "%02x", $0) }.joined()
        }
        return .init(checkpoint: checkpoint, fingerprints: fingerprints)
    }
}

/// A saved explanation is data, never an already-authorized live URL. Both
/// sides are reopened through the accepted immutable search snapshot contract.
actor MeetingAssignmentEvidenceReader {
    private let store: ProjectStore
    private let inputs: MeetingAssignmentInputReader
    private let reader: KnowledgeSearchSourceReader
    init(store: ProjectStore, meetingsRoot: URL, documentsRoot: URL) {
        self.store = store
        inputs = MeetingAssignmentInputReader(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
        reader = KnowledgeSearchSourceReader(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
    }
    func open(meetingID: String, projectID: UUID, context: Bool) async throws -> KnowledgeSearchDestination {
        let state = try await store.assignmentRuntimeSnapshot()
        guard let work = state.work[meetingID], work.state == .current,
              let decision = state.decisions[meetingID], decision.origin != .manual,
              let result = decision.result, let evidence = result.evidence.first(where: { $0.projectID == projectID }) else { throw MeetingAssignmentError.stale }
        let current = try await inputs.capture(additionalIDs: [meetingID])
        guard current.fingerprints[meetingID] == work.input,
              current.checkpoint.model.generation == result.modelGeneration,
              current.checkpoint.model.model?.id == result.modelID,
              current.checkpoint.model.model?.dimensions == result.dimensions else { throw MeetingAssignmentError.stale }
        let key = context ? evidence.contextSource : .init(kind: .meeting, externalID: meetingID)
        let chunk = context ? evidence.contextChunk : evidence.meetingChunk
        guard var source = current.checkpoint.sources.first(where: { $0.key == key }),
              (key.kind == .meeting ? source.observation.revision == chunk.revision : source.document?.contentHash == chunk.revision),
              !context || source.owners.contains(projectID) else { throw MeetingAssignmentError.stale }
        source.title = await reader.title(source)
        let hit = KnowledgeSearchHit(source: source, chunk: chunk, model: current.checkpoint.model,
            scope: context ? .project(projectID) : .all, matchedWords: false, matchedMeaning: true,
            fileStamp: result.sourceFileStamps[key.rawValue])
        try await store.validateKnowledgeSearchHit(hit)
        let content = try await reader.read(hit, includePDF: true)
        try await store.validateKnowledgeSearchHit(hit)
        let final = try await inputs.capture(additionalIDs: [meetingID])
        guard final.fingerprints[meetingID] == work.input else { throw MeetingAssignmentError.stale }
        try await store.validateAssignmentEvidence(work, decision: decision, checkpoint: final.checkpoint)
        try Task.checkCancellation()
        return .init(hit: hit, chunks: content.chunks, pdf: content.pdf, checkedAt: Date())
    }
}
