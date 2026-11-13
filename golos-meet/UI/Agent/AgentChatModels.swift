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

/// Элемент чат-потока «Агент».
enum AgentChatItem: Identifiable, Equatable {
    case userMessage(id: UUID, text: String, time: Date)
    case agentMessage(id: UUID, text: String, time: Date)
    case narration(id: UUID, text: String)
    case toolSteps(id: UUID, label: String, steps: [AgentToolStep])
    case artifact(AgentArtifact)
    case failure(id: UUID, text: String)

    var id: UUID {
        switch self {
        case .userMessage(let id, _, _), .agentMessage(let id, _, _),
             .narration(let id, _), .toolSteps(let id, _, _),
             .failure(let id, _):
            return id
        case .artifact(let artifact):
            return artifact.id
        }
    }
}
