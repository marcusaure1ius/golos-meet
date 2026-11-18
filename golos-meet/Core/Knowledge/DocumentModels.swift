import Foundation

nonisolated struct DocumentVersion: Sendable, Identifiable, Equatable {
    let id: UUID
    let documentID: UUID
    let contentHash: String
    let relativePath: String
    let originalName: String
    let importedAt: Date
    let warnings: [String]
    let chunkCount: Int
}

nonisolated struct LibraryDocument: Sendable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let currentVersion: DocumentVersion
    let versionCount: Int
    let projectIDs: Set<UUID>
}

nonisolated enum DocumentImportState: String, Sendable, Equatable {
    case queued, copying, extracting, indexing, saving, completed, failed, cancelled, interrupted
    var isTerminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
    var title: String {
        switch self {
        case .queued: return "В очереди"
        case .copying: return "Копирую файл"
        case .extracting: return "Извлекаю текст и выполняю OCR"
        case .indexing: return "Сохраняю фрагменты"
        case .saving: return "Сохраняю версию"
        case .completed: return "Готово"
        case .failed: return "Ошибка импорта"
        case .cancelled: return "Отменено"
        case .interrupted: return "Импорт прерван"
        }
    }
    var order: Int {
        switch self {
        case .queued: return 0
        case .copying: return 1
        case .extracting: return 2
        case .indexing: return 3
        case .saving: return 4
        default: return 5
        }
    }
}

nonisolated struct DocumentImportAttempt: Sendable, Identifiable, Equatable {
    let id: UUID
    let filename: String
    let targetID: UUID?
    let state: DocumentImportState
    let message: String
    let createdAt: Date
}

nonisolated struct DocumentImportProgress: Sendable {
    var state: DocumentImportState
    var completed: Int? = nil
    var total: Int? = nil
}

nonisolated struct DocumentImportResult: Sendable {
    let documentID: UUID
    let reused: Bool
}

nonisolated enum DocumentImportError: LocalizedError {
    case missingDocument, invalidRecord, unsafePath
    var errorDescription: String? {
        switch self {
        case .missingDocument: return "Документ больше не доступен. Обновите библиотеку."
        case .invalidRecord: return "Не удалось прочитать данные документа. Предыдущая версия сохранена."
        case .unsafePath: return "Недопустимый путь к копии документа."
        }
    }
}
