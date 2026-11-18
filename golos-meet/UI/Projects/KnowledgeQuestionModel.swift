import Foundation
import Combine

nonisolated enum KnowledgeQuestionPhase: Equatable { case idle, retrieving, prepared, generating, answered, cancelled, failed }
nonisolated struct KnowledgeQuestionNotice: Equatable {
    enum Kind: Equatable { case noContext, key, network, stale, invalid, input, unavailable }
    let kind: Kind
    let title: String
    let detail: String
}

/// The UI owns one session. Edits invalidate synchronously, before onChange or
/// the next render. All asynchronous publications also check the UI generation.
@MainActor final class KnowledgeQuestionModel: ObservableObject {
    typealias Factory = () throws -> KnowledgeQuestionService
    @Published var projectID: UUID? { didSet { if oldValue != projectID { reset() } } }
    @Published var question = "" { didSet { if oldValue != question { reset() } } }
    @Published var retrievalQuery = "" { didSet { if oldValue != retrievalQuery { reset() } } }
    @Published private(set) var phase: KnowledgeQuestionPhase = .idle
    @Published private(set) var request: KnowledgeQuestionRequest?
    @Published private(set) var result: KnowledgeQuestionResult?
    @Published private(set) var destination: KnowledgeSearchDestination?
    @Published private(set) var openingLabel: String?
    @Published private(set) var notice: KnowledgeQuestionNotice?
    let providerLabel: String
    private let factory: Factory
    private var service: KnowledgeQuestionService?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var subscription: KnowledgeIndexSubscription?

    init(projectID: UUID? = nil, providerLabel: String = "OpenRouter", center: NotificationCenter? = nil,
         factory: @escaping Factory) {
        self.projectID = projectID; self.providerLabel = providerLabel; self.factory = factory
        if let center {
            subscription = KnowledgeIndexSubscription(center: center) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.service != nil else { return }
                    self.fail(KnowledgeQuestionError.staleContext)
                }
            }
        }
    }

    var busy: Bool { phase == .retrieving || phase == .generating || openingLabel != nil }
    var needsRetrievalQuery: Bool { !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? KnowledgeSearchQuery.expression(question)) == nil }
    var canPrepare: Bool {
        projectID != nil && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && question.count <= 4000
            && (try? KnowledgeSearchQuery.expression(needsRetrievalQuery ? retrievalQuery : question)) != nil && !busy
    }
    var canSend: Bool { phase == .prepared && request?.denied == false }

    func reset() {
        generation = UUID(); operation?.cancel(); operation = nil
        service?.cancel(); service = nil
        request = nil; result = nil; destination = nil; openingLabel = nil; notice = nil; phase = .idle
    }
    func cancel() { reset(); phase = .cancelled }
    func prepare() {
        guard canPrepare, let projectID else { return }
        reset(); phase = .retrieving
        let id = generation, text = question, query = needsRetrievalQuery ? retrievalQuery : nil
        do { service = try factory() } catch { fail(error); return }
        guard let service else { return }
        operation = Task(priority: .utility) {
            do {
                let prepared = try await service.prepare(question: text, projectID: projectID, retrievalQuery: query)
                guard generation == id, !Task.isCancelled else { return }
                request = prepared; phase = .prepared; operation = nil
            } catch { publish(error, for: id) }
        }
    }

    /// This action is itself the explicit request-scoped consent, after the
    /// complete preview is visible. No token is retained by the model or view.
    func send() {
        guard canSend, let request, let service else { return }
        let id = generation
        phase = .generating; notice = nil
        operation = Task(priority: .utility) {
            do {
                let consent = request.approvalProjectIDs.isEmpty ? nil : try await service.approve(request)
                guard generation == id, !Task.isCancelled else { return }
                let answer = try await service.answer(request, consent: consent)
                guard generation == id, !Task.isCancelled else { return }
                result = answer; phase = .answered; operation = nil
            } catch { publish(error, for: id) }
        }
    }
    func open(_ label: String) {
        guard !busy, phase == .answered, let result, let service else { return }
        let id = generation
        openingLabel = label; notice = nil
        operation = Task(priority: .utility) {
            do {
                let target = try await service.openCitation(label, in: result)
                guard generation == id, !Task.isCancelled else { return }
                destination = target; openingLabel = nil; operation = nil
            } catch { publish(error, for: id) }
        }
    }
    func back() { destination = nil }
    private func publish(_ error: Error, for id: UUID) {
        guard generation == id else { return }
        if error is CancellationError { cancel() } else { fail(error) }
    }
    private func fail(_ error: Error) {
        reset(); phase = .failed
        switch error {
        case KnowledgeAnswerError.noContext:
            notice = .init(kind: .noContext, title: "Подходящих материалов нет", detail: "Добавьте документы или назначьте встречи этому проекту. Если материалы уже есть, уточните слова для поиска.")
        case LLMError.noAPIKey:
            notice = .init(kind: .key, title: "Нужен ключ OpenRouter", detail: "Сохраните ключ в настройках. Затем заново подготовьте контекст: прежнее согласие не сохраняется.")
        case let LLMError.http(status, _):
            notice = .init(kind: status == 401 || status == 403 ? .key : .network, title: status == 401 || status == 403 ? "Проверьте доступ к OpenRouter" : "Сервис не ответил", detail: "Код ответа: \(status). Повторите подготовку контекста перед новой отправкой.")
        case is URLError:
            notice = .init(kind: .network, title: "Не удалось получить ответ", detail: "Проверьте подключение к сети. Локальные материалы сохранены; повтор начнётся с подготовки контекста.")
        case KnowledgeAnswerError.invalidAnswer, KnowledgeAnswerError.invalidCitation, LLMError.decode, LLMError.emptyResponse:
            notice = .init(kind: .invalid, title: "Ответ не прошёл проверку", detail: "Ответ пуст, имеет неверный формат или содержит неподтверждённую ссылку. Подготовьте контекст заново и повторите запрос.")
        case KnowledgeSearchError.sourceChanged, KnowledgeSearchError.modelChanged, KnowledgeSearchError.scopeUnavailable,
             KnowledgeQuestionError.staleContext, KnowledgeQuestionError.superseded, KnowledgeAnswerError.cloudNotAllowed:
            notice = .init(kind: .stale, title: "Контекст или разрешения изменились", detail: "Обновите проекты и подготовьте контекст заново. Отправка требует разрешения каждого владельца источника.")
        case KnowledgeSearchError.invalidQuery, KnowledgeAnswerError.invalidQuestion, KnowledgeAnswerError.contextTooLarge:
            notice = .init(kind: .input, title: "Уточните вопрос или поиск", detail: error.localizedDescription)
        default:
            notice = .init(kind: .unavailable, title: "Вопрос пока недоступен", detail: "Не удалось прочитать материалы или проверить доступ. Повторите подготовку контекста; если ошибка сохраняется, проверьте настройки.")
        }
    }
    deinit { operation?.cancel() }
}
