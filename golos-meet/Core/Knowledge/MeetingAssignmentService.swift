import Foundation

nonisolated struct MeetingAssignmentPlan: Sendable {
    let meetingID: String
    let checkpoint: MeetingAssignmentCheckpoint
    let result: MeetingAssignmentResult
    let checkedHits: [KnowledgeSearchHit]
}

/// Compare only complete, verified trusted context; automatic/proposed meetings
/// never become training context. Publication preserves the accepted CAS fence.
actor MeetingAssignmentService {
    private let store: ProjectStore
    private let reader: KnowledgeSearchSourceReader
    private let windowBudget: Int
    private let comparisonBudget: Int
    static let algorithm = MeetingAssignmentPolicy.algorithm

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
        var preparations = 0
        func spend(_ count: Int) throws {
            try Task.checkCancellation()
            guard count <= comparisonBudget - preparations else { throw MeetingAssignmentError.limited }
            preparations += count
        }
        var aliases = Dictionary(uniqueKeysWithValues: checkpoint.projects.map { ($0.id, [$0.name]) })
        for anchor in anchors {
            for window in loaded[anchor.key] ?? [] {
                try spend(1 + anchor.owners.count)
                if let alias = MeetingAssignmentPolicy.trustedAlias(in: window.chunk.text) {
                    for id in anchor.owners { aliases[id, default: []].append(alias) }
                }
            }
        }
        try spend(aliases.values.reduce(0) { $0 + $1.count })
        let aliasTokens = aliases.mapValues { names in names.flatMap { [MeetingAssignmentPolicy.tokens($0), MeetingAssignmentPolicy.words($0)] } }
        let excluded = MeetingAssignmentPolicy.nameTerms(aliases.values.flatMap { $0 })
        var terms: [String: Set<String>] = [:]
        var projectTerms: [UUID: Set<String>] = [:]
        for source in [target] + anchors {
            for window in loaded[source.key] ?? [] {
                try spend(1 + source.owners.count)
                let content = MeetingAssignmentPolicy.terms(window.chunk.text, excluding: excluded)
                terms[window.chunk.id] = content
                if source.key != target.key {
                    for id in source.owners { projectTerms[id, default: []].formUnion(content) }
                }
            }
        }
        var termOwners: [String: Set<UUID>] = [:]
        for (id, content) in projectTerms {
            for term in content { termOwners[term, default: []].insert(id) }
        }
        var mentions: [String: Set<UUID>] = [:]
        for window in loaded.values.flatMap({ $0 }) {
            try spend(aliasTokens.values.reduce(0) { $0 + $1.count })
            let tokens = MeetingAssignmentPolicy.tokens(window.chunk.text)
            let raw = MeetingAssignmentPolicy.words(window.chunk.text)
            mentions[window.chunk.id] = Set(checkpoint.projects.filter { project in
                (aliasTokens[project.id] ?? []).contains {
                    MeetingAssignmentPolicy.contains($0, in: tokens) || MeetingAssignmentPolicy.contains($0, in: raw)
                }
            }.map(\.id))
        }
        // Conservative abstention across the entire meeting, including a negated
        // chunk separate from a tempting positive chunk. No entailment is claimed.
        let meetingBlocked = targetWindows.contains { MeetingAssignmentPolicy.blocked($0.chunk.text) }
        let contextBlocked = Set(anchors.flatMap { loaded[$0.key] ?? [] }.filter {
            MeetingAssignmentPolicy.blocked($0.chunk.text)
        }.map { $0.chunk.id })
        var candidates: [MeetingAssignmentEvidence] = []
        var scores: [String: [UUID: Double]] = [:]
        var comparisons = preparations
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
                        guard checkpoint.projects.contains(where: { $0.id == id }) else { throw MeetingAssignmentError.stale }
                        scores[meeting.chunk.id, default: [:]][id] = max(scores[meeting.chunk.id]?[id] ?? -1, score)
                        guard score >= MeetingAssignmentPolicy.proposalThreshold else { continue }
                        let declared = mentions[meeting.chunk.id] ?? []
                        let explicit = declared == [id]
                            && mentions[context.chunk.id]?.contains(id) == true
                        let shared = (terms[meeting.chunk.id] ?? []).intersection(terms[context.chunk.id] ?? [])
                        let support = MeetingAssignmentSupport(sharedTerms: shared.sorted(),
                            distinctiveTerms: shared.filter { termOwners[$0] == [id] }.sorted(),
                            meetingTermCount: terms[meeting.chunk.id]?.count ?? 0,
                            blocked: meetingBlocked || contextBlocked.contains(context.chunk.id)
                                || !declared.subtracting([id]).isEmpty)
                        candidates.append(.init(projectID: id, meetingChunk: meeting.chunk,
                            contextSource: anchor.key, contextChunk: context.chunk, similarity: score,
                            explicitName: explicit, competingSimilarity: 0, support: support))
                    }
                }
            }
        }
        // Compare projects for the SAME meeting chunk. A name does not override
        // stronger evidence that the actual subject belongs to another project.
        var best: [UUID: MeetingAssignmentEvidence] = [:]
        var automatic: Set<UUID> = []
        let confident = MeetingAssignmentPolicy.confident
        for candidate in candidates {
            let competitor = scores[candidate.meetingChunk.id]?.filter { $0.key != candidate.projectID }.map(\.value).max() ?? 0
            let item = MeetingAssignmentEvidence(projectID: candidate.projectID, meetingChunk: candidate.meetingChunk,
                contextSource: candidate.contextSource, contextChunk: candidate.contextChunk,
                similarity: candidate.similarity, explicitName: candidate.explicitName, competingSimilarity: competitor, support: candidate.support)
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

}
