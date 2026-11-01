import Foundation

nonisolated enum MemoryUpdateError: Error, LocalizedError, Equatable {
    case invalidContext, notReady, contextTooLarge, candidateLimit, stale, superseded, consentRequired, invalidConsent, invalidReply, invalidReference
    var errorDescription: String? {
        switch self {
        case .invalidContext: "Выберите фрагменты готовых источников проекта."
        case .notReady: "Дождитесь готовности актуального локального индекса."
        case .contextTooLarge: "Выбранный контекст слишком велик. Разделите обновление."
        case .candidateLimit: "В группе уже 256 действующих утверждений. Явно отмените ненужное или замените несколько одним; история сохранится. Повтор без изменения набора не поможет."
        case .stale: "Источники, разрешения или память изменились. Подготовьте новый запрос."
        case .superseded: "Обновление отменено или заменено новым запросом."
        case .consentRequired: "Нужно разовое разрешение всех владельцев выбранного контекста."
        case .invalidConsent: "Разрешение устарело или относится к другому обновлению."
        case .invalidReply: "Модель вернула неполные или некорректные утверждения. Память не изменена."
        case .invalidReference: "В ответе есть неподтверждённая ссылка, цитата или дата. Память не изменена."
        }
    }
}
nonisolated enum MemoryUpdateState: Equatable, Sendable {
    case idle, preparing, waiting, denied, needsConsent, ready, running, updated, insufficientEvidence, cancelled, stale, limited, failed
}
nonisolated struct MemoryUpdateVersion: Equatable, Sendable {
    let projectID: UUID
    let generation: String
    let revision: Int
}
nonisolated struct MemoryUpdateCheckpoint: Equatable, Sendable {
    let projects: [KnowledgeProject]
    let parentVersions: [MemoryUpdateVersion]
}
nonisolated enum MemoryUpdateOutcome: Equatable, Sendable {
    case published(MemoryPublication), insufficientEvidence
}
nonisolated struct MemoryUpdateGuard: Sendable {
    let hits: [KnowledgeSearchHit]
    let checkpoint: MemoryUpdateCheckpoint
}
