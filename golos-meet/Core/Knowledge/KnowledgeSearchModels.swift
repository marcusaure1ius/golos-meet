import Foundation

nonisolated enum KnowledgeSearchScope: Hashable, Sendable {
    case all, inbox, project(UUID)
    func contains(_ owners: Set<UUID>) -> Bool {
        switch self {
        case .all: true
        case .inbox: owners.isEmpty
        case .project(let id): owners.contains(id)
        }
    }
}

nonisolated struct KnowledgeSearchModelStamp: Equatable, Sendable {
    let model: EmbeddingIndexModel?
    let generation: String
}

nonisolated struct KnowledgeSearchSource: Equatable, Sendable {
    let observation: EmbeddingSourceObservation
    let job: EmbeddingIndexJob
    let owners: Set<UUID>
    var title: String
    let document: DocumentVersion?
    var key: EmbeddingSourceKey { observation.key }

    func hasSameIdentity(as other: Self, requiresVectors: Bool) -> Bool {
        observation == other.observation && job.generation == other.job.generation
            && job.modelID == other.job.modelID && owners == other.owners
            && document?.id == other.document?.id && document?.contentHash == other.document?.contentHash
            && (!requiresVectors || other.job.state == .ready)
    }
}

nonisolated struct KnowledgeSearchCatalog: Sendable {
    let model: KnowledgeSearchModelStamp
    let sources: [KnowledgeSearchSource]
}

nonisolated struct KnowledgeSearchChunk: Sendable {
    let source: EmbeddingSourceKey
    let chunk: KnowledgeChunk
}

nonisolated struct KnowledgeSearchHit: Identifiable, Sendable {
    let source: KnowledgeSearchSource
    let chunk: KnowledgeChunk
    let model: KnowledgeSearchModelStamp
    let scope: KnowledgeSearchScope
    let matchedWords: Bool
    let matchedMeaning: Bool
    let fileStamp: String?
    var id: String { chunk.id }
}

nonisolated struct KnowledgeSearchResponse: Sendable {
    let hits: [KnowledgeSearchHit]
    let semanticMessage: String?
    let pendingSources: Int
    let failedSources: Int
    let limited: Bool
}

/// The viewer receives the SAME validated bytes/chunks, never a path which it
/// rereads after validation. It presents a versioned snapshot, not a live file.
nonisolated struct KnowledgeSearchDestination: Identifiable, Sendable {
    let hit: KnowledgeSearchHit
    let chunks: [KnowledgeChunk]
    let pdf: Data?
    let checkedAt: Date
    var id: String { hit.id }
}

nonisolated enum KnowledgeSearchError: Error, LocalizedError, Equatable {
    case invalidQuery, sourceChanged, modelChanged, scopeUnavailable, indexRepairing, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidQuery: "Введите от одного до 20 слов, не больше 256 символов."
        case .sourceChanged: "Источник или его индекс изменился. Повторите поиск, чтобы открыть актуальный фрагмент."
        case .modelChanged: "Модель поиска изменилась. Повторите запрос."
        case .scopeUnavailable: "Этот проект больше недоступен. Выберите другую область поиска."
        case .indexRepairing: "Индекс источника повреждён и отправлен на повторную обработку. Дождитесь её завершения и повторите поиск."
        case .unavailable: "Не удалось выполнить локальный поиск. Повторите запрос."
        }
    }
}

nonisolated enum KnowledgeSearchQuery {
    /// Only quoted Unicode words reach MATCH; user FTS operators are data.
    static func expression(_ text: String) throws -> String {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 256 else { throw KnowledgeSearchError.invalidQuery }
        let words = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 20 else { throw KnowledgeSearchError.invalidQuery }
        return words.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }
}
