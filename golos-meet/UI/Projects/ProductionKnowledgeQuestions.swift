import Foundation
import SwiftUI

/// Продакшн-проводка RAG-пайплайна «Вопросов» (#113/#123). Экран «Вопросы»
/// удалён и свёрнут в Агента; слой сохраняется как будущий инструмент агента
/// `answer_question` (контекст → модель → ответ с источниками): модель,
/// фабрика и клиент не удаляются, семантику согласий покрывают модельные тесты.
@MainActor enum ProductionKnowledgeQuestions {
    static func makeModel(projectID: UUID? = nil) -> KnowledgeQuestionModel? {
        // Must precede shared library/runtime/settings and any Keychain access.
        guard !AppRuntime.isTestHost, let search = ProductionKnowledgeSearch.service else { return nil }
        let store = ProjectLibrary.shared.store
        let meetings = AppPaths.meetingsRoot, documents = AppPaths.appSupport.appendingPathComponent("knowledge")
        let model = UISettings.shared.generationModel.rawValue
        return KnowledgeQuestionModel(projectID: projectID, providerLabel: "OpenRouter · " + model, center: .default) {
            KnowledgeQuestionService(store: store, search: search, meetingsRoot: meetings, documentsRoot: documents,
                                     client: QuestionOpenRouterClient(), model: model)
        }
    }
}

/// Credentials are resolved only when a permitted send starts. Neither a render
/// nor local retrieval reads Keychain. Tests/isolated hosts inject a fake client.
struct QuestionOpenRouterClient: ChatCompleter {
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        try await complete(model: model, messages: messages, responseFormat: responseFormat, beforeSending: {})
    }
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?,
                              beforeSending: @escaping @Sendable () async throws -> Void) async throws -> String {
        let key = try await MainActor.run {
            guard !AppRuntime.isTestHost else { throw LLMError.noAPIKey }
            guard let data = try Keychain.readChecked(account: Keychain.openRouterAccount),
                  let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw LLMError.noAPIKey }
            return value
        }
        try Task.checkCancellation()
        return try await OpenRouterClient(apiKey: key).complete(model: model, messages: messages,
            responseFormat: responseFormat, beforeSending: beforeSending)
    }
}
