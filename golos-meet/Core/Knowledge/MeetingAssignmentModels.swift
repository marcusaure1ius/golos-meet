import Foundation

nonisolated enum MeetingAssignmentOrigin: String, Codable, Sendable { case manual, automatic, proposal }

nonisolated struct MeetingAssignmentDecision: Codable, Equatable, Sendable {
    let origin: MeetingAssignmentOrigin
    let generation: String
    let result: MeetingAssignmentResult?
}

/// Scores are cosine similarities, never calibrated probabilities. Evidence
/// carries both sides of a comparison, preserving source revision and location.
nonisolated struct MeetingAssignmentEvidence: Codable, Equatable, Sendable {
    let projectID: UUID
    let meetingChunk: KnowledgeChunk
    let contextSource: EmbeddingSourceKey
    let contextChunk: KnowledgeChunk
    let similarity: Double
    let explicitName: Bool
    let competingSimilarity: Double
}

nonisolated struct MeetingAssignmentResult: Codable, Equatable, Sendable {
    let assignedProjectIDs: Set<UUID>
    let evidence: [MeetingAssignmentEvidence]
    let suggestedTopic: String?
    let algorithm: String
    let modelID: String
    let modelGeneration: String
    let dimensions: Int
    let sourceFileStamps: [String: String]
    let projectNames: [UUID: String]
}

nonisolated struct MeetingAssignmentCheckpoint: Equatable, Sendable {
    let epoch: String
    let projects: [KnowledgeProject]
    let model: KnowledgeSearchModelStamp
    let sources: [KnowledgeSearchSource]
    let decisions: [String: MeetingAssignmentDecision]
    let contextKeys: Set<EmbeddingSourceKey>
}

nonisolated enum MeetingAssignmentCommit: Sendable, Equatable { case applied, unchanged, manual, superseded }

nonisolated enum MeetingAssignmentError: Error, LocalizedError {
    case notReady, limited, stale
    var errorDescription: String? {
        switch self {
        case .notReady: "Для распределения нужен готовый локальный индекс встречи и контекста проекта."
        case .limited: "Слишком много фрагментов для одного расчёта распределения. Назначения не изменены."
        case .stale: "Источники или проекты изменились. Распределение нужно пересчитать."
        }
    }
}
