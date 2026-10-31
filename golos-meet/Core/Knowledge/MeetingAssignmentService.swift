import Foundation

nonisolated struct MeetingAssignmentPlan: Sendable {
    let meetingID: String
    let checkpoint: MeetingAssignmentCheckpoint
    let result: MeetingAssignmentResult
    let checkedHits: [KnowledgeSearchHit]
}

/// Explicit-name rule + local passage similarity. Semantic closeness alone is
/// only a proposal. Auto-linked meetings NEVER become project training context.
/// No runtime hooks/UI yet: callers must explicitly prepare and commit a plan.
actor MeetingAssignmentService {
    private let store: ProjectStore
    private let reader: KnowledgeSearchSourceReader
    private let windowBudget: Int
    private let comparisonBudget: Int
    static let algorithm = "explicit-name-margin-e5-v2"

    init(store: ProjectStore, meetingsRoot: URL, documentsRoot: URL,
         windowBudget: Int = 2_000, comparisonBudget: Int = 100_000) {
        self.store = store
        reader = KnowledgeSearchSourceReader(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
        self.windowBudget = max(0, windowBudget); self.comparisonBudget = max(0, comparisonBudget)
    }

    /// nil means a durable manual decision (including explicit Inbox).
    func prepare(meetingID: String) async throws -> MeetingAssignmentPlan? {
        let checkpoint = try await store.meetingAssignmentCheckpoint()
        if checkpoint.decisions[meetingID]?.origin == .manual { return nil }
        guard let model = checkpoint.model.model,
              let target = checkpoint.sources.first(where: { $0.key == .init(kind: .meeting, externalID: meetingID) }),
              target.job.state == .ready, target.job.modelID == model.id else { throw MeetingAssignmentError.notReady }
        guard checkpoint.projects.count <= 200 else { throw MeetingAssignmentError.limited }
        let expectedContext = checkpoint.contextKeys.subtracting([target.key])
        let anchors = checkpoint.sources.filter { expectedContext.contains($0.key) }
        // Partial context, including a malformed transcript already removed
        // from search, must not silently become a confident classification.
        guard Set(anchors.map(\.key)) == expectedContext,
              anchors.allSatisfy({ !$0.owners.isEmpty && $0.job.state == .ready && $0.job.modelID == model.id }) else { throw MeetingAssignmentError.notReady }
        var loaded: [EmbeddingSourceKey: [StoredEmbeddingWindow]] = [:]
        var hits: [KnowledgeSearchHit] = [], used = 0
        for source in [target] + anchors {
            try Task.checkCancellation()
            let count = try await store.knowledgeVectorCount(for: source.key)
            guard count > 0 else { throw MeetingAssignmentError.notReady }
            guard count <= windowBudget - used else { throw MeetingAssignmentError.limited }
            used += count
            let stamp = try await reader.identity(source)
            let windows = try await store.embeddingWindows(for: source.key, model: model)
            guard windows.count == count, let first = windows.first else { throw MeetingAssignmentError.stale }
            let hit = KnowledgeSearchHit(source: source, chunk: first.chunk, model: checkpoint.model,
                scope: .all, matchedWords: false, matchedMeaning: true, fileStamp: stamp)
            let verified = try await reader.read(hit, includePDF: false)
            guard windows.allSatisfy({ verified.chunks.contains($0.chunk) }) else { throw MeetingAssignmentError.stale }
            loaded[source.key] = windows; hits.append(hit)
        }
        let targetWindows = loaded[target.key] ?? []
        let names = Dictionary(grouping: checkpoint.projects, by: { Self.words($0.name) })
        var candidates: [MeetingAssignmentEvidence] = []
        var scores: [String: [UUID: Double]] = [:]
        var comparisons = 0
        for anchor in anchors {
            for context in loaded[anchor.key] ?? [] {
                for meeting in targetWindows {
                    try Task.checkCancellation()
                    comparisons += 1
                    guard comparisons <= comparisonBudget else { throw MeetingAssignmentError.limited }
                    let score = try meeting.vector.cosineSimilarity(to: context.vector)
                    for id in anchor.owners.sorted(by: { $0.uuidString < $1.uuidString }) {
                        comparisons += 1
                        guard comparisons <= comparisonBudget else { throw MeetingAssignmentError.limited }
                        guard let project = checkpoint.projects.first(where: { $0.id == id }) else { throw MeetingAssignmentError.stale }
                        scores[meeting.chunk.id, default: [:]][id] = max(scores[meeting.chunk.id]?[id] ?? -1, score)
                        guard score >= 0.90 else { continue }
                        let name = Self.words(project.name)
                        let explicit = !name.isEmpty && name.joined().count >= 5 && names[name]?.count == 1
                            && Self.contains(name, in: meeting.chunk.text) && Self.contains(name, in: context.chunk.text)
                            && !Self.words(meeting.chunk.text).contains(where: { ["не", "нет", "чужой", "отменён", "отменен"].contains($0) })
                        candidates.append(.init(projectID: id, meetingChunk: meeting.chunk,
                            contextSource: anchor.key, contextChunk: context.chunk, similarity: score,
                            explicitName: explicit, competingSimilarity: 0))
                    }
                }
            }
        }
        // Compare projects for the SAME meeting chunk. A name does not override
        // stronger evidence that the actual subject belongs to another project.
        var best: [UUID: MeetingAssignmentEvidence] = [:]
        var automatic: Set<UUID> = []
        func confident(_ item: MeetingAssignmentEvidence) -> Bool {
            item.explicitName && item.similarity >= 0.90 && item.similarity - item.competingSimilarity >= 0.04
        }
        for candidate in candidates {
            let competitor = scores[candidate.meetingChunk.id]?.filter { $0.key != candidate.projectID }.map(\.value).max() ?? 0
            let item = MeetingAssignmentEvidence(projectID: candidate.projectID, meetingChunk: candidate.meetingChunk,
                contextSource: candidate.contextSource, contextChunk: candidate.contextChunk,
                similarity: candidate.similarity, explicitName: candidate.explicitName, competingSimilarity: competitor)
            if confident(item) { automatic.insert(item.projectID) }
            if let previous = best[item.projectID] {
                if (confident(item) && !confident(previous)) || (confident(item) == confident(previous) && item.similarity > previous.similarity) { best[item.projectID] = item }
            } else { best[item.projectID] = item }
        }
        let evidence = best.values.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
        let topic = evidence.isEmpty ? targetWindows.first.map { String($0.chunk.text.prefix(100)) } : nil
        let result = MeetingAssignmentResult(assignedProjectIDs: automatic, evidence: evidence,
                                            suggestedTopic: topic, algorithm: Self.algorithm,
                                            modelID: model.id, modelGeneration: checkpoint.model.generation, dimensions: model.dimensions,
                                            sourceFileStamps: Dictionary(uniqueKeysWithValues: hits.compactMap { hit in
                                                hit.fileStamp.map { (hit.source.key.rawValue, $0) }
                                            }), projectNames: Dictionary(uniqueKeysWithValues: checkpoint.projects.map { ($0.id, $0.name) }))
        let plan = MeetingAssignmentPlan(meetingID: meetingID, checkpoint: checkpoint, result: result, checkedHits: hits)
        try await validate(plan)
        return plan
    }

    func commit(_ plan: MeetingAssignmentPlan, runtimeLease: MeetingAssignmentLease? = nil) async throws -> MeetingAssignmentCommit {
        try Task.checkCancellation()
        try await validate(plan)
        try Task.checkCancellation()
        return try await store.commitMeetingAssignment(plan.result, meetingID: plan.meetingID, checkpoint: plan.checkpoint, runtimeLease: runtimeLease)
    }

    private func validate(_ plan: MeetingAssignmentPlan) async throws {
        for hit in plan.checkedHits {
            try Task.checkCancellation()
            _ = try await reader.read(hit, includePDF: false)
        }
        // Recheck all identities after the potentially slow content reads,
        // including a source read before another source changed on disk.
        for hit in plan.checkedHits {
            guard try await reader.identity(hit.source) == hit.fileStamp else { throw MeetingAssignmentError.stale }
        }
        try await store.validateKnowledgeSearchHits(plan.checkedHits, model: plan.checkpoint.model)
        guard try await store.meetingAssignmentCheckpoint() == plan.checkpoint else { throw MeetingAssignmentError.stale }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func contains(_ phrase: [String], in text: String) -> Bool {
        let tokens = words(text)
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return false }
        return (0...(tokens.count - phrase.count)).contains { Array(tokens[$0..<($0 + phrase.count)]) == phrase }
    }
}
