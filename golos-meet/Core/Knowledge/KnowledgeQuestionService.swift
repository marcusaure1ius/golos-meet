import Foundation

nonisolated struct KnowledgeQuestionCheckpoint: Equatable, Sendable {
    let epoch: String
    let projects: [KnowledgeProject]
}

/// Created only by the service; an approval can never authorize a caller's
/// replacement question/chunks/owners. No credentials or whole archive here.
nonisolated struct KnowledgeQuestionRequest: Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let question: String
    let hits: [KnowledgeSearchHit]
    let checkpoint: KnowledgeQuestionCheckpoint
    let searchResponse: KnowledgeSearchResponse
    let textCharacterCount: Int
    fileprivate init(id: UUID, projectID: UUID, question: String, hits: [KnowledgeSearchHit],
                     checkpoint: KnowledgeQuestionCheckpoint, searchResponse: KnowledgeSearchResponse) {
        self.id = id; self.projectID = projectID; self.question = question; self.hits = hits
        self.checkpoint = checkpoint; self.searchResponse = searchResponse
        textCharacterCount = hits.reduce(0) { $0 + $1.chunk.text.count + $1.source.title.count }
    }
    var approvalProjectIDs: Set<UUID> {
        Set(checkpoint.projects.filter { $0.cloudPolicy == .askEveryTime }.map(\.id))
    }
    var denied: Bool { checkpoint.projects.contains { $0.cloudPolicy == .localOnly } }
}

nonisolated struct KnowledgeQuestionConsent: Sendable {
    fileprivate let id: UUID
    fileprivate let requestID: UUID
}

nonisolated struct KnowledgeQuestionResult: Sendable {
    let request: KnowledgeQuestionRequest
    let answer: KnowledgeAnswer
    fileprivate init(request: KnowledgeQuestionRequest, answer: KnowledgeAnswer) {
        self.request = request; self.answer = answer
    }
}

nonisolated enum KnowledgeQuestionError: Error, LocalizedError, Equatable {
    case superseded, staleContext, consentRequired, invalidConsent
    var errorDescription: String? {
        switch self {
        case .superseded: "Вопрос отменён или выбран другой запрос/проект."
        case .staleContext: "Контекст или разрешения изменились. Повторите поиск и проверьте выбранные материалы."
        case .consentRequired: "Для отправки выбранных фрагментов нужно разовое разрешение всех владельцев."
        case .invalidConsent: "Это разрешение не относится к текущему вопросу или уже использовано."
        }
    }
}

/// One instance per question UI session. Changing project/question must call
/// cancel() or prepare(). Every await is fenced; even an uncancellable provider
/// may not publish a reply into the next session. This service has no UI hooks,
/// Keychain access or implicit production paths.
@MainActor final class KnowledgeQuestionService {
    private let store: ProjectStore
    private let search: KnowledgeSearchService
    private let reader: KnowledgeSearchSourceReader
    private let generator: KnowledgeAnswerGenerator
    private var currentID: UUID?
    private var pending: KnowledgeQuestionRequest?
    private var consent: KnowledgeQuestionConsent?

    init(store: ProjectStore, search: KnowledgeSearchService, meetingsRoot: URL, documentsRoot: URL,
         client: ChatCompleter, model: String) {
        self.store = store; self.search = search
        reader = KnowledgeSearchSourceReader(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
        generator = .init(client: client, model: model)
    }

    func cancel() {
        currentID = nil; pending = nil; consent = nil
    }

    /// Uses the accepted search's 256-character / 20-word query contract. A
    /// longer answer question can supply a separate concise retrievalQuery.
    func prepare(question: String, projectID: UUID, retrievalQuery: String? = nil) async throws -> KnowledgeQuestionRequest {
        cancel()
        let id = UUID(); currentID = id
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 4000 else { throw KnowledgeAnswerError.invalidQuestion }
        let before = try await store.questionCheckpoint(projectID: projectID, hits: [])
        try requireCurrent(id)
        let response = try await search.search(retrievalQuery ?? question, scope: .project(projectID))
        try requireCurrent(id)
        var hits: [KnowledgeSearchHit] = [], characters = 0
        for hit in response.hits {
            let count = hit.chunk.text.count + hit.source.title.count
            if hits.count < 12 && characters + count <= 16_000 { hits.append(hit); characters += count }
        }
        guard !hits.isEmpty else {
            throw response.hits.isEmpty ? KnowledgeAnswerError.noContext : KnowledgeAnswerError.contextTooLarge
        }
        let checkpoint = try await store.questionCheckpoint(projectID: projectID, hits: hits)
        guard before.epoch == checkpoint.epoch else { throw KnowledgeQuestionError.staleContext }
        let request = KnowledgeQuestionRequest(id: id, projectID: projectID, question: question,
                                               hits: hits, checkpoint: checkpoint, searchResponse: response)
        try await validate(request)
        pending = request
        return request
    }

    /// Called by the explicit confirmation action for THIS immutable preview.
    /// Returning a token is not a persisted policy change.
    func approve(_ request: KnowledgeQuestionRequest) async throws -> KnowledgeQuestionConsent {
        guard pending?.id == request.id else { throw KnowledgeQuestionError.invalidConsent }
        try await validate(request)
        guard pending?.id == request.id else { throw KnowledgeQuestionError.invalidConsent }
        guard !request.denied else { throw KnowledgeAnswerError.cloudNotAllowed }
        let value = KnowledgeQuestionConsent(id: UUID(), requestID: request.id)
        consent = value
        return value
    }

    func answer(_ request: KnowledgeQuestionRequest, consent approval: KnowledgeQuestionConsent? = nil) async throws -> KnowledgeQuestionResult {
        try requireCurrent(request.id)
        guard pending?.id == request.id else { throw KnowledgeQuestionError.invalidConsent }
        // Consume BEFORE suspension, including failed/cancelled attempts. Retry
        // by preparing a new preview; the same token cannot authorize two calls.
        pending = nil
        let issued = consent; consent = nil
        guard !request.denied else { throw KnowledgeAnswerError.cloudNotAllowed }
        if let approval {
            guard approval.id == issued?.id, approval.requestID == request.id else { throw KnowledgeQuestionError.invalidConsent }
        } else if !request.approvalProjectIDs.isEmpty { throw KnowledgeQuestionError.consentRequired }
        try await validate(request)
        guard let project = request.checkpoint.projects.first(where: { $0.id == request.projectID }) else {
            throw KnowledgeAnswerError.cloudNotAllowed
        }
        let context = request.hits.map {
            KnowledgeAnswerContext(sourceTitle: $0.source.title, chunk: $0.chunk, ownerProjectIDs: $0.source.owners,
                                   sourceRevision: $0.source.observation.revision,
                                   importedAt: $0.source.document?.importedAt)
        }
        let answer = try await generator.answer(question: request.question, project: project,
            context: context, projects: request.checkpoint.projects,
            approvedProjectIDs: approval == nil ? [] : request.approvalProjectIDs,
            beforeSending: { [self] in try await self.validate(request) })
        // Do not return source bytes or model text after revocation, a changed
        // source/model or a switch, even when the transport ignored cancellation.
        try await validate(request)
        return .init(request: request, answer: answer)
    }

    func openCitation(_ label: String, in result: KnowledgeQuestionResult) async throws -> KnowledgeSearchDestination {
        try requireCurrent(result.request.id)
        guard let citation = result.answer.citations.first(where: { $0.label == label }),
              let hit = result.request.hits.first(where: {
                  $0.chunk.id == citation.chunkID && $0.chunk.sourceID == citation.sourceID
                    && $0.chunk.revision == citation.revision && $0.source.observation.revision == citation.sourceRevision
                    && $0.chunk.location == citation.location
              }) else { throw KnowledgeAnswerError.invalidCitation }
        let destination = try await search.open(hit)
        try requireCurrent(result.request.id)
        return destination
    }

    private func requireCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard currentID == id else { throw KnowledgeQuestionError.superseded }
    }

    /// Local cutoff: file stamps + hashes/chunks are validated first, then ONE
    /// SQLite transaction compares source/model/owner/policy generations, then
    /// the session/cancellation fence, immediately before transport dispatch.
    /// Files, SQLite, actors and a remote server are NOT one atomic transaction.
    /// Mutations after this cutoff cannot recall bytes already sent. Retries run
    /// this gate again, and returned answers get the same postflight validation.
    private func validate(_ request: KnowledgeQuestionRequest) async throws {
        try requireCurrent(request.id)
        var checked: Set<EmbeddingSourceKey> = []
        for hit in request.hits where checked.insert(hit.source.key).inserted {
            _ = try await reader.read(hit, includePDF: false)
            try requireCurrent(request.id)
        }
        // Recheck earlier files after later asynchronous reads as well.
        for hit in request.hits {
            guard try await reader.identity(hit.source) == hit.fileStamp else { throw KnowledgeSearchError.sourceChanged }
            try requireCurrent(request.id)
        }
        let current = try await store.questionCheckpoint(projectID: request.projectID, hits: request.hits)
        guard current == request.checkpoint else { throw KnowledgeQuestionError.staleContext }
        try requireCurrent(request.id)
    }
}
