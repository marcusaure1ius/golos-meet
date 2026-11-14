import Foundation

// MARK: - Элементы чат-потока агента
//
// Поверхность (UI) для issue #94: модель потока рассчитана на подключение
// реального агента (dsh-рантайм) за один слой — каждый тип события потока
// соответствует наблюдаемым паттернам AutoClaw (research/agent-ui-94/SPEC.md):
// narration (П3), артефакты-карточки (П4), сообщения (П2), согласие (П5).

/// Один шаг инструментальной работы агента (команда/действие с результатом).
struct AgentToolStep: Identifiable, Equatable {
    let id: UUID
    let label: String
    let result: String?

    init(label: String, result: String? = nil) {
        self.id = UUID()
        self.label = label
        self.result = result
    }
}

/// Карточка-артефакт, встроенная в поток (П4 SPEC.md).
struct AgentArtifact: Identifiable, Equatable {
    enum Kind: Equatable {
        case meeting            // найденная встреча
        case summary            // конспект встречи
        case projectSuggestion  // предложение проекта
        case rawContext         // raw-контекст consent-запроса (раскрытие фрагментов)
    }

    let id: UUID
    let kind: Kind
    let title: String
    let meta: String          // строка метаданных (дата, длительность, статус)
    let body: String
    let points: [String]      // action points для конспекта / шаги для предложения
    let sourceLabel: String   // честный источник (П4 SPEC.md: артефакт имеет источник)
    /// id встречи-источника, если артефакт привязан к встрече.
    let meetingID: String?

    init(kind: Kind, title: String, meta: String, body: String,
         points: [String] = [], sourceLabel: String, meetingID: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.meta = meta
        self.body = body
        self.points = points
        self.sourceLabel = sourceLabel
        self.meetingID = meetingID
    }
}

/// Запрос согласия на отправку контекста проекта во внешний сервис (П5 SPEC.md,
/// consent-in-chat #94). Кнопки-действия встроены в сообщение агента; решение
/// для разового согласия относится только к этому запросу — политика проекта
/// в принятом хранилище (ProjectStore.cloud_policy) не меняется (#37: разовое
/// разрешение не превращается в постоянный допуск). Состояние карточки
/// обновляется после действия пользователя; текущая политика читается из
/// того же API, что использует панель памяти (ProjectLibrary/ProjectStore).
struct AgentConsentRequest: Identifiable, Equatable {
    enum State: Equatable {
        case pending    // ждёт решения пользователя
        case approved   // «Разрешить эту часть» — разовое согласие этого запроса
        case cancelled  // «Отменить» — ничего не отправлялось
        case denied     // политика проекта запрещает отправку (localOnly)
    }

    let id: UUID
    let projectID: UUID
    let projectName: String
    /// Полный размер собранного контекста (как в narration «12 из 128»).
    let fragmentCount: Int
    /// Фрагменты, которые будут отправлены (после фильтра пустых сегментов).
    let fragments: [String]
    /// Честный получатель и назначение отправки.
    let recipient: String
    /// Честная метка текущей политики проекта из принятого хранилища.
    let policyLabel: String
    /// Честная пометка о дате источника: поисковый слой не даёт проверенной
    /// даты источника (MemorySourceReference.sourceDate == nil).
    let sourceDateKnown: Bool
    /// Разовое согласие возможно только при политике «Спрашивать каждый раз»;
    /// «Только локально» — запрет владельца, который разовое согласие не
    /// отменяет (принятое поведение #35/#37).
    let allowsOneTimeApproval: Bool
    private(set) var state: State = .pending

    init(projectID: UUID, projectName: String, fragmentCount: Int, fragments: [String],
         recipient: String, policyLabel: String, sourceDateKnown: Bool = false,
         allowsOneTimeApproval: Bool = true) {
        self.id = UUID()
        self.projectID = projectID
        self.projectName = projectName
        self.fragmentCount = fragmentCount
        self.fragments = fragments
        self.recipient = recipient
        self.policyLabel = policyLabel
        self.sourceDateKnown = sourceDateKnown
        self.allowsOneTimeApproval = allowsOneTimeApproval
    }

    mutating func resolve(_ state: State) { self.state = state }
}

/// Элемент чат-потока «Агент».
enum AgentChatItem: Identifiable, Equatable {
    case userMessage(id: UUID, text: String, time: Date)
    case agentMessage(id: UUID, text: String, time: Date)
    case narration(id: UUID, text: String)
    case toolSteps(id: UUID, label: String, steps: [AgentToolStep])
    case artifact(AgentArtifact)
    case consent(AgentConsentRequest)
    case failure(id: UUID, text: String)

    var id: UUID {
        switch self {
        case .userMessage(let id, _, _), .agentMessage(let id, _, _),
             .narration(let id, _), .toolSteps(let id, _, _),
             .failure(let id, _):
            return id
        case .consent(let request):
            return request.id
        case .artifact(let artifact):
            return artifact.id
        }
    }
}
