import Foundation
import Combine

/// Модель чат-потока «Агент» (issue #94, ночной спринт W3/W4).
///
/// Демо-режим: детерминированный мок-агент поверх реальных данных QA-архива
/// через принятые сервисы (`MeetingLibrary`, поисковый индекс). Облачных
/// вызовов нет; narration и tool-шаги повторяют структуру будущих событий
/// dsh-рантайма (W1), чтобы подключить реального агента за один слой.
///
/// Consent-in-chat (W4): запросы на отправку контекста проекта выдаются
/// narration + карточкой согласия с кнопками прямо в сообщении. Политики
/// per-project читаются из принятого слоя (`ProjectLibrary` → `ProjectStore`,
/// тот же API, что использует панель памяти); разовое согласие относится
/// только к конкретному запросу и не меняет политику проекта (#37).
@MainActor
final class AgentChatModel: ObservableObject {
    @Published private(set) var items: [AgentChatItem] = []
    @Published var draft: String = ""
    @Published private(set) var isThinking = false

    /// Задержка между шагами narration (в тестах — .zero).
    private let stepDelay: Duration
    private let library: MeetingLibrary
    /// Принятый слой проектов/политик (панель памяти использует тот же API).
    private let projects: ProjectLibrary?
    private var runTask: Task<Void, Never>?

    init(library: MeetingLibrary, projects: ProjectLibrary? = nil, stepDelay: Duration = .milliseconds(350)) {
        self.library = library
        self.projects = projects
        self.stepDelay = stepDelay
    }

    /// Общее число шагов во всех блоках .toolSteps. Растёт и при добавлении
    /// шага в существующий блок — лента должна доскролливать и на это
    /// (P3 ревью #97: onChange(items.count) этого не ловит).
    var totalToolSteps: Int {
        items.reduce(0) { if case .toolSteps(_, _, let steps) = $1 { $0 + steps.count } else { $0 } }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        isThinking = false
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        runTask?.cancel()
        items.append(.userMessage(id: UUID(), text: text, time: Date()))
        isThinking = true
        runTask = Task { [weak self] in
            await self?.run(text: text)
        }
    }

    // MARK: - Детерминированный мок-агент

    private func run(text: String) async {
        library.reload()
        let query = text.lowercased()
        let summaries = library.summaries.filter { $0.hasTranscript && $0.status == .ready }

        await narrate("Просматриваю архив встреч…")
        await step("Считаю расшифрованные встречи", result: "\(summaries.count) встреч готовы")
        guard !Task.isCancelled else { return }

        guard !summaries.isEmpty else {
            items.append(.agentMessage(
                id: UUID(),
                text: "В архиве пока нет расшифрованных встреч, поэтому ответить по данным не получится. Запишите встречу и вернитесь к этому вопросу.",
                time: Date()))
            isThinking = false
            return
        }

        if Self.isMemoryConsolidationIntent(query) {
            await answerWithMemoryConsolidation(summaries: summaries, query: text)
        } else if Self.isSummaryIntent(query) {
            await answerWithSummary(summaries: summaries, query: query)
        } else if Self.isProjectIntent(query) {
            await answerWithProjectSuggestion(summaries: summaries, query: text)
        } else {
            await answerWithSearch(summaries: summaries, query: query)
        }
        if !Task.isCancelled { isThinking = false }
    }

    // MARK: - Consent-in-chat: сведение памяти проекта (#94, фаза 2)

    private func answerWithMemoryConsolidation(summaries: [MeetingSummary], query: String) async {
        guard let projects else {
            items.append(.agentMessage(
                id: UUID(),
                text: "Работа с памятью проекта недоступна: слой проектов не подключён к агенту. Откройте панель памяти проекта, чтобы управлять согласиями.",
                time: Date()))
            return
        }
        let snapshot = projects.snapshot
        let tokens = Self.queryTokens(query.lowercased()).filter { !Self.memoryIntentWords.contains($0) }
        let candidates = snapshot.projects.filter { project in
            tokens.isEmpty || tokens.contains { project.name.localizedCaseInsensitiveContains($0) }
        }
        guard let project = candidates.first else {
            let names = snapshot.projects.map { "«\($0.name)»" }.joined(separator: ", ")
            items.append(.agentMessage(
                id: UUID(),
                text: names.isEmpty
                    ? "Пока нет ни одного проекта, память которого можно сводить. Создайте проект и назначьте ему встречи."
                    : "Проект с таким названием не нашёлся. Доступные проекты: \(names).",
                time: Date()))
            return
        }

        await step("Собираю фрагменты проекта «\(project.name)»", result: nil)
        let assigned = summaries.filter { summary in
            (snapshot.meetingProjects[summary.id] ?? []).contains(project.id)
        }
        var fragments: [String] = []
        for summary in assigned {
            if Task.isCancelled { return }
            do {
                let segments = try library.transcriptSegments(for: summary.id)
                fragments.append(contentsOf: segments.map(\.text))
            } catch {
                // Честный сбой чтения данных: не маскируем пустотой (П5 SPEC.md,
                // оживляем ветку .failure из ревью #97).
                items.append(.failure(
                    id: UUID(),
                    text: "Не удалось прочитать расшифровку встречи «\(summary.title)»: \(error.localizedDescription). Ничего не отправлялось — проверьте данные и повторите."))
                return
            }
        }
        let filtered = Self.presentableFragments(fragments)
        if assigned.isEmpty {
            items.append(.agentMessage(
                id: UUID(),
                text: "В проекте «\(project.name)» пока нет встреч, назначенных ему. Назначьте встречи проекту — тогда я смогу собрать их фрагменты для памяти.",
                time: Date()))
            return
        }

        // Политика проекта — из принятого хранилища, как это делает панель памяти.
        switch project.cloudPolicy {
        case .allowSelectedContext:
            await narrate("Политика проекта разрешает отправку выбранного контекта — новое согласие не требуется.")
            await showConsentContext(project: project, fragments: filtered)
            items.append(.agentMessage(
                id: UUID(),
                text: "Контекст проекта «\(project.name)» (\(filtered.count) \(Self.pluralFragments(filtered.count))) разрешён к отправке в OpenRouter по политике проекта. В демо-режиме реальная генерация сводки не выполняется — её сделает агентный рантайм после подключения.",
                time: Date()))
        case .localOnly:
            await narrate("Собрал \(filtered.count) \(Self.pluralFragments(filtered.count)) проекта «\(project.name)», но отправлять их нельзя.")
            items.append(.consent(AgentConsentRequest(
                projectID: project.id, projectName: project.name,
                fragmentCount: filtered.count, fragments: Array(filtered.prefix(Self.maxConsentFragments)),
                recipient: Self.consentRecipient, policyLabel: project.cloudPolicy.questionLabel,
                allowsOneTimeApproval: false)))
        case .askEveryTime:
            await narrate("Собрал \(filtered.count) \(Self.pluralFragments(filtered.count)) из \(assigned.count) \(Self.pluralMeetings(assigned.count)) проекта «\(project.name)». Для сведения памяти их нужно отправить в OpenRouter — нужно ваше разрешение.")
            items.append(.consent(AgentConsentRequest(
                projectID: project.id, projectName: project.name,
                fragmentCount: filtered.count, fragments: Array(filtered.prefix(Self.maxConsentFragments)),
                recipient: Self.consentRecipient, policyLabel: project.cloudPolicy.questionLabel)))
        }
    }

    /// Raw-контекст согласия — карточкой с раскрытием (12 фрагментов, как в QA).
    private func showConsentContext(project: KnowledgeProject, fragments: [String]) async {
        items.append(.artifact(AgentArtifact(
            kind: .rawContext,
            title: "Контекст проекта «\(project.name)»",
            meta: "\(fragments.count) \(Self.pluralFragments(fragments.count)) расшифровок · получатель OpenRouter",
            body: "Фрагменты транскриптов встреч проекта, собранные локально. Дата источника неизвестна: поисковый слой не даёт проверенной даты для этих фрагментов.",
            points: Array(fragments.prefix(Self.maxConsentFragments)),
            sourceLabel: "Источники: транскрипты встреч проекта",
            meetingID: nil)))
        await pause()
    }

    /// «Разрешить эту часть»: разовое согласие для этого запроса. Политика
    /// проекта перечитывается из принятого слоя перед решением — если она
    /// изменилась, согласие не выдаётся и запрашивается заново.
    func approveConsent(_ requestID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == requestID }),
              case .consent(var request) = items[index], request.state == .pending else { return }
        let policy = projects?.snapshot.projects.first { $0.id == request.projectID }?.cloudPolicy
        guard policy == .askEveryTime || policy == .allowSelectedContext else {
            request.resolve(.denied)
            items[index] = .consent(request)
            items.append(.narration(id: UUID(), text: "Политика проекта запрещает отправку: разовое согласие не отменяет запрет владельца."))
            return
        }
        request.resolve(.approved)
        items[index] = .consent(request)
        items.append(.narration(id: UUID(), text: "Разрешение учтено для этого запроса (политика проекта осталась «\(request.policyLabel)»). Реальную отправку в \(request.recipient) выполнит агентный рантайм; в демо-режиме сеть не используется."))
    }

    /// «Отменить»: ни один фрагмент не покидает устройство.
    func cancelConsent(_ requestID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == requestID }),
              case .consent(var request) = items[index], request.state == .pending else { return }
        request.resolve(.cancelled)
        items[index] = .consent(request)
        items.append(.narration(id: UUID(), text: "Отправка отменена. Ни один фрагмент проекта «\(request.projectName)» не покинул устройство."))
    }

    private func answerWithSearch(summaries: [MeetingSummary], query: String) async {
        let tokens = Self.queryTokens(query)
        await step("Ищу по словам: \(tokens.joined(separator: ", "))", result: nil)
        var matches: [(MeetingSummary, String)] = []
        for summary in summaries {
            if Task.isCancelled { return }
            let haystack = library.searchText(for: summary.id)
            let hitToken = tokens.first { haystack.contains($0) }
            if let hitToken {
                matches.append((summary, hitToken))
            }
        }
        await narrate("Готовлю результаты…")
        if matches.isEmpty {
            items.append(.agentMessage(
                id: UUID(),
                text: "По этим словам в расшифровках ничего не нашлось. Попробуйте другое слово из разговора — я ищу по заголовкам, конспектам и транскриптам.",
                time: Date()))
            return
        }
        items.append(.agentMessage(
            id: UUID(),
            text: "Нашёл \(matches.count) \(Self.pluralMeetings(matches.count)) по этим словам:",
            time: Date()))
        for (summary, token) in matches.prefix(3) {
            items.append(.artifact(Self.meetingArtifact(summary, matchedToken: token)))
        }
        if matches.count > 3 {
            items.append(.narration(id: UUID(), text: "Ещё \(matches.count - 3) встреч — уточните слова, чтобы сузить поиск."))
        }
    }

    private func answerWithSummary(summaries: [MeetingSummary], query: String) async {
        await step("Открываю конспект последней встречи", result: nil)
        // Для конспекта берём последнюю готовую встречу с инсайтами; если её нет —
        // честно сообщаем (состояние «неизвестно» не маскируется, П8 SPEC.md).
        let withInsights = summaries.first { $0.hasInsights && library.insights(for: $0.id) != nil }
        guard let summary = withInsights, let insights = library.insights(for: summary.id) else {
            items.append(.agentMessage(
                id: UUID(),
                text: "У последних встреч ещё нет конспектов (insights.json). Конспект появится после обработки встречи — спросите позже.",
                time: Date()))
            return
        }
        await narrate("Собираю итоги и договорённости…")
        items.append(.agentMessage(
            id: UUID(),
            text: "Вот конспект последней встречи с готовым конспектом:",
            time: Date()))
        items.append(.artifact(AgentArtifact(
            kind: .summary,
            title: insights.title,
            meta: Self.metaLine(summary),
            body: insights.summary,
            points: insights.actionPoints.map(\.text),
            sourceLabel: "Источники: конспект и транскрипт встречи «\(summary.title)»",
            meetingID: summary.id)))
    }

    private func answerWithProjectSuggestion(summaries: [MeetingSummary], query: String) async {
        await step("Группирую встречи по смыслу", result: nil)
        let tokens = Self.queryTokens(query.lowercased()).filter { !Self.intentWords.contains($0) }
        let candidates = tokens.isEmpty ? summaries.prefix(2).map { ($0, "") } : summaries.compactMap { summary -> (MeetingSummary, String)? in
            let haystack = library.searchText(for: summary.id)
            if let token = tokens.first(where: { haystack.contains($0) }) { return (summary, token) }
            return nil
        }
        await narrate("Формулирую предложение…")
        guard !candidates.isEmpty else {
            items.append(.agentMessage(
                id: UUID(),
                text: "Чтобы предложить проект, назовите тему — найду встречи по словам и предложу состав проекта.",
                time: Date()))
            return
        }
        let name = candidates.first?.0.title ?? query
        items.append(.agentMessage(
            id: UUID(),
            text: "Предлагаю проект по теме «\(name)». Состав — по найденным встречам:",
            time: Date()))
        items.append(.artifact(AgentArtifact(
            kind: .projectSuggestion,
            title: "Проект: \(name)",
            meta: "\(candidates.count) \(Self.pluralMeetings(candidates.count)) в основе",
            body: "Собрать встреч\(candidates.count == 1 ? "у" : "и") в проект и вести накопительный контекст по теме.",
            points: candidates.prefix(3).map { "Включить: \($0.0.title)" },
            sourceLabel: "Предложение собрано из поисковой выдачи, без изменений данных",
            meetingID: nil)))
    }

    // MARK: - Шаги narration (П3 SPEC.md)

    private func narrate(_ text: String) async {
        items.append(.narration(id: UUID(), text: text))
        await pause()
    }

    private func step(_ label: String, result: String?) async {
        await toolStepBlock(label: label, result: result)
    }

    /// Добавляет шаг в последний блок .toolSteps (или открывает новый блок).
    /// Внутренний, чтобы тесты проверяли рост счётчика скролла (ревью #97).
    func toolStepBlock(label: String, result: String?) async {
        let step = AgentToolStep(label: label, result: result)
        // Группируем подряд идущие шаги в один свёрнутый блок.
        if case .toolSteps(_, _, var steps)? = items.last {
            steps.append(step)
            items[items.count - 1] = .toolSteps(id: items.last!.id, label: "Работа с архивом", steps: steps)
        } else {
            items.append(.toolSteps(id: UUID(), label: "Работа с архивом", steps: [step]))
        }
        await pause()
    }

    private func pause() async {
        guard stepDelay > .zero else { return }
        try? await Task.sleep(for: stepDelay)
    }

    // MARK: - Детерминированные правила

    private static let intentWords: Set<String> = ["найди", "найти", "поищи", "поиск", "покажи", "показать", "спроси", "спросить", "мне", "по"]

    /// Слова интента сведения памяти — сами по себе не имя проекта.
    private static let memoryIntentWords: Set<String> = ["сведи", "свести", "своди", "сводка", "память", "памятью", "проекта", "проект"]

    /// Сколько фрагментов контекста показывается в карточке (как в QA #93).
    static let maxConsentFragments = 12
    /// Честный получатель для consent-карточки (генерация — OpenRouter).
    static let consentRecipient = "OpenRouter"

    private static func isMemoryConsolidationIntent(_ query: String) -> Bool {
        ["сведи", "свести", "своди", "сводка", "свед", "памят"].contains { query.contains($0) }
    }

    /// Пустые реплики («а.», «да.») не являются содержательным фрагментом
    /// контекста — фильтр <5 символов после trim (#93 P3).
    static func presentableFragments(_ texts: [String]) -> [String] {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 5 }
    }

    static func pluralFragments(_ n: Int) -> String {
        if (11...14).contains(n % 100) { return "фрагментов" }
        switch n % 10 {
        case 1: return "фрагмент"
        case 2, 3, 4: return "фрагмента"
        default: return "фрагментов"
        }
    }

    private static func isSummaryIntent(_ query: String) -> Bool {
        ["договорил", "конспект", "итог", "резюме", "action", "пункты"].contains { query.contains($0) }
    }

    private static func isProjectIntent(_ query: String) -> Bool {
        query.contains("проект") || query.contains("предложи")
    }

    private static func queryTokens(_ query: String) -> [String] {
        query.split { !$0.isLetter }.map(String.init).filter { $0.count > 2 && !intentWords.contains($0) }
    }

    private static func meetingArtifact(_ summary: MeetingSummary, matchedToken: String) -> AgentArtifact {
        AgentArtifact(
            kind: .meeting,
            title: summary.title,
            meta: metaLine(summary),
            body: "Совпадение по слову «\(matchedToken)».",
            points: [],
            sourceLabel: "Источники: транскрипт встречи",
            meetingID: summary.id)
    }

    private static func metaLine(_ summary: MeetingSummary) -> String {
        let date = Self.dateFormatter.string(from: summary.startedAt)
        return "\(date) · \(summary.durationText) · \(summary.status.label)"
    }

    private static func pluralMeetings(_ n: Int) -> String {
        if (11...14).contains(n % 100) { return "встреч" }
        switch n % 10 {
        case 1: return "встречу"
        case 2, 3, 4: return "встречи"
        default: return "встреч"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
