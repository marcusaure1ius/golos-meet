import Foundation

nonisolated struct LocalEmbeddingCandidate: Sendable {
    let model: EmbeddingIndexModel
    let folder: URL?
    let load: @Sendable () async throws -> any LocalPassageEmbedding

    /// Inspect verifies managed local files; it never downloads a model.
    static func installed(using installer: EmbeddingModelInstaller) async throws -> Self? {
        guard let folder = try await installer.installedFolder() else { return nil }
        return .init(model: .e5Small, folder: folder, load: { try await E5TextEmbedding(folder: folder) })
    }
}

nonisolated enum LocalIndexModelState: String, Sendable { case idle, checking, missing, ready, failed }

nonisolated struct LocalIndexingSnapshot: Sendable {
    var revision: UInt64 = 0
    var modelState: LocalIndexModelState = .idle
    var hasWorkingModel = false
    var modelMessage = "Модель ещё не проверена."
    var storageMessage: String?
    var jobs: [EmbeddingIndexJob] = []
    var counts: [EmbeddingIndexState: Int] = [:]
    var titles: [EmbeddingSourceKey: String] = [:]
    var sourceErrors: [EmbeddingSourceKey: String] = [:]
}

nonisolated enum LocalIndexingError: Error, LocalizedError {
    case missingModel, superseded
    var errorDescription: String? {
        switch self {
        case .missingModel: "Для поиска по смыслу установите локальную модель в настройках."
        case .superseded: "Модель изменилась во время расчёта. Повторите запрос."
        }
    }
}
