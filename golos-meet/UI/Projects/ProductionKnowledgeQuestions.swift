import Foundation
import SwiftUI

@MainActor enum ProductionKnowledgeQuestions {
    static func makeModel(projectID: UUID? = nil) -> KnowledgeQuestionModel? {
        // Must precede shared library/runtime/settings and any Keychain access.
        guard !AppRuntime.isTestHost, let search = ProductionKnowledgeSearch.service else { return nil }
        let store = ProjectLibrary.shared.store
        let meetings = AppPaths.meetingsRoot, documents = AppPaths.appSupport.appendingPathComponent("knowledge")
        let model = UISettings.shared.llmModel
        return KnowledgeQuestionModel(projectID: projectID, providerLabel: "OpenRouter · " + model, center: .default) {
            KnowledgeQuestionService(store: store, search: search, meetingsRoot: meetings, documentsRoot: documents,
                                     client: QuestionOpenRouterClient(), model: model)
        }
    }
}

/// Credentials are resolved only on the explicit send action. Neither a render
/// nor local retrieval reads Keychain. Tests/isolated hosts inject a fake client.
private struct QuestionOpenRouterClient: ChatCompleter {
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

struct KnowledgeQuestionEntry: View {
    var initialProjectID: UUID?
    var onBack: (() -> Void)?
    var onSettings: (() -> Void)?
    @State private var model: KnowledgeQuestionModel?
    @State private var loaded = false
    var body: some View {
        ZStack {
            if let model { KnowledgeQuestionScreen(model: model, onBack: onBack, onSettings: onSettings) }
            else if loaded { ContentUnavailableView("Вопросы недоступны в тестовом host", systemImage: "text.bubble") }
            else { ProgressView("Подготавливаем вопросы…") }
        }.task {
            if !loaded { model = ProductionKnowledgeQuestions.makeModel(projectID: initialProjectID); loaded = true }
        }.onDisappear { model?.cancel() }
    }
}
