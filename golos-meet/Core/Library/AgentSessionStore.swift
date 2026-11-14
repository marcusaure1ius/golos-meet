import Foundation
import os

// MARK: - Сессии чата «Агент» (issue #117)
//
// Паттерн Core/Library: хранилище сессий чата «Агент» на диске, отдельно от
// модели потока (AgentChatModel ведёт живую ленту и вызывает хранилище).
// Одна сессия = один JSON-файл `<uuid>.json` в `agent/sessions/` AppSupport
// (в тестовом host — изолированный временный каталог, как у meetings/).
// Порядок «последних» сессий — по mtime файла: каждая запись потока обновляет
// mtime, поэтому сессия с последним сообщением всегда сверху.

/// Одна сессия чата «Агент»: метаданные + полный поток элементов.
struct AgentSession: Codable, Equatable, Identifiable {
    let id: UUID
    /// Дата создания сессии (первого «Нового чата»).
    var createdAt: Date
    /// Авто-заголовок из первого вопроса (≤60 символов); nil, пока вопросов нет.
    var title: String?
    /// Полный поток чата (те же элементы, что и в живой ленте).
    var items: [AgentChatItem]
    /// Версия схемы; nil у будущих старых файлов (поле введено в #117).
    var schemaVersion: Int?

    init(id: UUID = UUID(), createdAt: Date = Date(), title: String? = nil,
         items: [AgentChatItem] = [], schemaVersion: Int? = AgentSession.currentSchemaVersion) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.items = items
        self.schemaVersion = schemaVersion
    }

    static let currentSchemaVersion = 1

    static func encoded(_ session: AgentSession) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Даты — числом (timeIntervalSinceReferenceDate): round-trip должен
        // быть точным. ISO-8601 режет субсекундную часть (даже с долями
        // секунды остаётся миллисекундная точность), а восстановленная
        // сессия сравнивается с потоком в памяти побитово.
        enc.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        return try enc.encode(session)
    }

    static func decoded(_ data: Data) throws -> AgentSession {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let seconds = try container.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return try dec.decode(AgentSession.self, from: data)
    }

    func write(to url: URL) throws { try Self.encoded(self).write(to: url, options: .atomic) }
}

/// Строка списка сессий (без потока): для меню «История» и сайдбара.
struct AgentSessionSummary: Identifiable, Equatable {
    let id: UUID
    let title: String?
    let createdAt: Date
    /// mtime файла сессии — «последняя активность», по нему идёт сортировка.
    let updatedAt: Date
}

/// Чтение, сохранение, удаление и листинг сессий чата «Агент» на диске.
/// Мутации файла атомарны; повреждённый файл не рушит список (пропускается).
@MainActor
final class AgentSessionsStore {
    private let root: URL

    init(root: URL = AppPaths.agentSessionsRoot) {
        self.root = root
    }

    // MARK: Чтение

    /// Полная сессия по id; nil — файла нет или он повреждён.
    func load(id: UUID) -> AgentSession? {
        let url = sessionURL(id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? AgentSession.decoded(data)
    }

    /// Последняя сессия по mtime (для восстановления при старте).
    func latestSessionID() -> UUID? {
        summaries().first?.id
    }

    /// Список сессий, отсортированный по mtime (свежие сверху).
    func summaries() -> [AgentSessionSummary] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [AgentSessionSummary] = []
        for entry in entries where entry.pathExtension == "json" {
            guard let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent) else { continue }
            let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard let data = try? Data(contentsOf: entry),
                  let session = try? AgentSession.decoded(data) else {
                Log.library.error("agent session \(entry.lastPathComponent, privacy: .public) is unreadable, skipped")
                continue
            }
            result.append(AgentSessionSummary(id: id, title: session.title,
                                              createdAt: session.createdAt, updatedAt: mtime))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Мутации

    /// Сохраняет сессию атомарно (mtime обновляется — сессия становится «последней»).
    func save(_ session: AgentSession) throws {
        try session.write(to: sessionURL(session.id))
    }

    /// Удаляет файл сессии. Несуществующая сессия — не ошибка.
    func delete(id: UUID) throws {
        let url = sessionURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        Log.library.info("agent session deleted: \(id.uuidString, privacy: .public)")
    }

    private func sessionURL(_ id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json")
    }
}
