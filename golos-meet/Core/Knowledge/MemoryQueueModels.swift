import Foundation

nonisolated enum MemoryQueueState: String, Codable, Sendable {
    case queued, running, partial, backpressured, waiting, denied, needsConsent, completed, insufficient, failed, limited, cancelled, stale
}
nonisolated struct MemoryQueueJob: Identifiable, Equatable, Sendable {
    let sequence: Int64
    let projectID: UUID
    let source: EmbeddingSourceKey
    let input: String
    let cycle: String
    let generation: String
    let state: MemoryQueueState
    let completedChunks: Int
    let totalChunks: Int
    let selectedInputKey: String?
    let message: String
    var id: String { projectID.uuidString + "|" + source.rawValue }
    var completeCoverage: Bool { totalChunks > 0 && completedChunks == totalChunks && [.completed, .insufficient].contains(state) }
}
nonisolated struct MemoryQueueLease: Sendable {
    let runID: String
    let attempt: String
    let job: MemoryQueueJob
    let count: Int
    let fileStamp: String
}
nonisolated struct MemoryQueueSnapshot: Sendable {
    var jobs: [MemoryQueueJob] = []
    var revision = 0
    var message: String?
    var backpressured = false
}
nonisolated struct MemoryQueueSourceDependency: Codable, Equatable, Sendable {
    let source: MemorySourceReference
    let jobGeneration: String
    let modelID: String
}
nonisolated struct MemoryQueueManualVersion: Codable, Equatable, Sendable {
    let projectID: UUID
    let sequence: Int64
}
nonisolated struct MemoryQueueDependencies: Codable, Equatable, Sendable {
    var sources: [MemoryQueueSourceDependency] = []
    var projects: [KnowledgeProject] = []
    var manual: [MemoryQueueManualVersion] = []
    // nil marks a pre-fix v8 row whose consumed ancestry was not recorded.
    // Reconcile resets it rather than claiming that its coverage is current.
    var memories: [UUID]? = []
    var ownRetirements: [UUID]? = []
}
nonisolated enum MemoryQueueError: Error, LocalizedError, Equatable {
    case stale, busy, budget, notReady
    var errorDescription: String? {
        switch self {
        case .stale: "Поколение очереди или её зависимости изменились. Подготовьте обновление заново."
        case .busy: "Предыдущая операция ещё завершается. Дождитесь её отмены."
        case .budget: "Один фрагмент или цепочка зависимостей превышает безопасный бюджет. Требуется разделить источник."
        case .notReady: "Источник или локальный индекс ещё не готов."
        }
    }
}
