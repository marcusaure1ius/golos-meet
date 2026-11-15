import Foundation
import Testing
@testable import golos_meet

/// Фикстура сессий чата «Агент» (#117): временный каталог хранилища сессий
/// и пустой QA-архив для MeetingLibrary — рабочие данные пользователя
/// не затрагиваются (изоляция test host дополнительно ведёт AppPaths
/// во временный каталог процесса).
@MainActor
private struct AgentSessionsFixture {
    let storeRoot: URL
    let archiveRoot: URL
    let store: AgentSessionsStore
    let library: MeetingLibrary

    init() throws {
        storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-sessions-\(UUID().uuidString)", isDirectory: true)
        archiveRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        store = AgentSessionsStore(root: storeRoot)
        library = MeetingLibrary(root: archiveRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: storeRoot)
        try? FileManager.default.removeItem(at: archiveRoot)
    }
}

@MainActor
@Suite struct AgentSessionStoreTests {
    // MARK: Round-trip сохранение → восстановление

    /// Полный round-trip: все виды элементов потока, включая consent-карточку
    /// в resolved-состоянии, восстанавливаются равными (issue #117).
    @Test func roundTripPreservesAllItemKinds() throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let consent = AgentConsentRequest(
            projectID: UUID(), projectName: "Прайсинг", fragmentCount: 12,
            fragments: ["Обсудили скидку 10%"], recipient: "OpenRouter",
            policyLabel: "Спрашивать каждый раз")
        var resolved = consent
        resolved.resolve(.approved)

        let session = AgentSession(
            // Дробная часть обязательна: целосекундные даты не поймали бы
            // усечение субсекундной точности при кодировании (ревью #127).
            createdAt: Date(timeIntervalSince1970: 1_763_000_000.1234567),
            title: "Найди встречи по слову прайсинг",
            items: [
                .userMessage(id: UUID(), text: "Найди встречи", time: Date(timeIntervalSince1970: 1.9876543)),
                .agentMessage(id: UUID(), text: "Нашёл 2 встречи", time: Date(timeIntervalSince1970: 2.1234567)),
                .narration(id: UUID(), text: "Просматриваю архив встреч…"),
                .toolSteps(id: UUID(), label: "Работа с архивом",
                           steps: [AgentToolStep(label: "Считаю встречи", result: "2 готовы")]),
                .artifact(AgentArtifact(kind: .meeting, title: "Прайсинг ноября",
                                        meta: "05.11.2026", body: "Совпадение по слову «прайсинг».",
                                        points: [], sourceLabel: "Источники: транскрипт",
                                        meetingID: "2026-11-05_10-00-00")),
                .consent(resolved),
                .failure(id: UUID(), text: "Честный сбой"),
            ])

        try f.store.save(session)
        let loaded = try #require(f.store.load(id: session.id), "Сессия должна восстановиться")

        #expect(loaded == session)
        #expect(loaded.title == session.title)
        #expect(loaded.createdAt == session.createdAt)
        #expect(loaded.items.count == 7)
        // Resolved-состояние согласия переживает round-trip: восстановленная
        // сессия не показывает решённое согласие как ожидающее.
        guard case .consent(let restoredRequest) = loaded.items[5] else {
            Issue.record("Ожидалась consent-карточка")
            return
        }
        #expect(restoredRequest.state == .approved)
    }

    /// Последняя сессия — по mtime файла: повторное сохранение старой сессии
    /// поднимает её наверх списка (это «последняя активность»).
    @Test func latestFollowsMostRecentSave() async throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let first = AgentSession(title: "Первый вопрос", items: [.narration(id: UUID(), text: "a")])
        try f.store.save(first)
        try await Task.sleep(for: .milliseconds(20))
        let second = AgentSession(title: "Второй вопрос", items: [.narration(id: UUID(), text: "b")])
        try f.store.save(second)

        #expect(f.store.latestSessionID() == second.id)
        #expect(f.store.summaries().map(\.id) == [second.id, first.id])

        // Активность в первой сессии снова делает её последней.
        var touched = first
        touched.items.append(.userMessage(id: UUID(), text: "уточнение", time: Date()))
        try f.store.save(touched)
        #expect(f.store.latestSessionID() == first.id)
    }

    /// Удаление убирает файл; повторное удаление и несуществующая сессия —
    /// не ошибка.
    @Test func deleteRemovesFileAndIsSafeOnMissing() throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let session = AgentSession(title: "t", items: [.narration(id: UUID(), text: "x")])
        try f.store.save(session)
        let url = f.storeRoot.appendingPathComponent("\(session.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: url.path))

        try f.store.delete(id: session.id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(f.store.load(id: session.id) == nil)
        #expect(f.store.summaries().isEmpty)

        // Идемпотентность.
        try f.store.delete(id: session.id)
        try f.store.delete(id: UUID())
    }

    /// Повреждённый файл сессии не рушит список — он пропускается.
    @Test func unreadableFileIsSkipped() throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let good = AgentSession(title: "живая", items: [])
        try f.store.save(good)
        let garbage = f.storeRoot.appendingPathComponent("\(UUID().uuidString).json")
        try Data("не json".utf8).write(to: garbage)

        let summaries = f.store.summaries()
        #expect(summaries.map(\.id) == [good.id])
        #expect(f.store.latestSessionID() == good.id)
    }
}

@MainActor
@Suite struct AgentSessionModelTests {
    /// Отправка первого вопроса: автозаголовок и сохранение на диск.
    @Test func sendPersistsStreamAndSetsAutoTitle() async throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let model = AgentChatModel(library: f.library, stepDelay: .zero, store: f.store)
        model.draft = "Найди встречи по слову прайсинг"
        model.send()
        try await AgentChatTests.waitIdle(model)

        let loaded = try #require(f.store.load(id: model.sessionID), "Сессия сохраняется после send")
        #expect(loaded.title == "Найди встречи по слову прайсинг")
        #expect(model.sessionTitle == loaded.title)
        #expect(loaded.items == model.items)
        #expect(loaded.items.contains { if case .userMessage(_, let text, _) = $0 { return text.contains("прайсинг") } else { return false } })
        #expect(loaded.items.contains { if case .agentMessage = $0 { return true } else { return false } })
    }

    /// «Новый чат»: пустой поток и новая сессия; старая остаётся на диске
    /// нетронутой и доступна в списке.
    @Test func newSessionKeepsOldOnDisk() async throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let model = AgentChatModel(library: f.library, stepDelay: .zero, store: f.store)
        model.draft = "Первый вопрос"
        model.send()
        try await AgentChatTests.waitIdle(model)

        let oldID = model.sessionID
        let oldURL = f.storeRoot.appendingPathComponent("\(oldID.uuidString).json")
        let oldData = try Data(contentsOf: oldURL)

        model.startNewSession()

        #expect(model.items.isEmpty)
        #expect(model.sessionID != oldID)
        #expect(model.sessionTitle == nil)
        // Старая сессия не изменилась побайтово и видна в истории.
        #expect(try Data(contentsOf: oldURL) == oldData)
        #expect(f.store.summaries().map(\.id) == [oldID])
        // Пустая новая сессия ещё не записана: файл появляется после первого
        // сообщения, а не при старте (нет пустых файлов).
        #expect(f.store.load(id: model.sessionID) == nil)
    }

    /// Переключение сессий: выбор из истории загружает её поток; обе сессии
    /// сохранены на диске.
    @Test func openSessionLoadsStreamOfChosenSession() async throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let model = AgentChatModel(library: f.library, stepDelay: .zero, store: f.store)
        model.draft = "Вопрос про прайсинг"
        model.send()
        try await AgentChatTests.waitIdle(model)
        let firstID = model.sessionID
        let firstItems = model.items

        model.startNewSession()
        model.draft = "Второй вопрос"
        model.send()
        try await AgentChatTests.waitIdle(model)
        let secondID = model.sessionID
        #expect(firstID != secondID)
        #expect(f.store.summaries().count == 2)

        // Переключение на первую.
        model.openSession(id: firstID)
        #expect(model.sessionID == firstID)
        #expect(model.items == firstItems)
        #expect(model.sessionTitle == "Вопрос про прайсинг")

        // Неизвестная сессия — текущая остаётся без изменений.
        model.openSession(id: UUID())
        #expect(model.sessionID == firstID)
    }

    /// Удаление чужой сессии убирает её с диска и из истории, не трогая
    /// текущую; удаление текущей — это «новый чат».
    @Test func deleteRemovesForeignAndResetsCurrent() async throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let model = AgentChatModel(library: f.library, stepDelay: .zero, store: f.store)
        model.draft = "Первый вопрос"
        model.send()
        try await AgentChatTests.waitIdle(model)
        let firstID = model.sessionID

        model.startNewSession()
        model.draft = "Второй вопрос"
        model.send()
        try await AgentChatTests.waitIdle(model)
        #expect(model.sessionID != firstID)
        let currentItems = model.items

        // Удаление не-текущей сессии.
        model.deleteSession(id: firstID)
        #expect(f.store.load(id: firstID) == nil)
        #expect(!f.store.summaries().map(\.id).contains(firstID))
        #expect(model.sessionID != firstID)
        #expect(model.items == currentItems)

        // Удаление текущей = новый чат: файл убран, поток пуст.
        let currentID = model.sessionID
        model.deleteSession(id: currentID)
        #expect(f.store.load(id: currentID) == nil)
        #expect(model.items.isEmpty)
        #expect(model.sessionID != currentID)
        #expect(model.sessionTitle == nil)
    }

    /// Восстановление при старте: init с хранилищем поднимает последнюю
    /// сессию по mtime (перезапуск приложения → последний чат на месте).
    @Test func initRestoresLatestSession() async throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let older = AgentSession(title: "Старая", items: [
            .userMessage(id: UUID(), text: "старый вопрос", time: Date()),
        ])
        try f.store.save(older)
        try await Task.sleep(for: .milliseconds(20))
        let newer = AgentSession(title: "Новая", items: [
            .userMessage(id: UUID(), text: "новый вопрос", time: Date()),
            .agentMessage(id: UUID(), text: "новый ответ", time: Date()),
        ])
        try f.store.save(newer)

        let model = AgentChatModel(library: f.library, stepDelay: .zero, store: f.store)
        #expect(model.sessionID == newer.id)
        #expect(model.items == newer.items)
        #expect(model.sessionTitle == "Новая")

        // Без хранилища — чистый поток в памяти (обратная совместимость
        // существующих тестов и превью).
        let bare = AgentChatModel(library: f.library, stepDelay: .zero)
        #expect(bare.items.isEmpty)
        #expect(!bare.hasSessionPersistence)
    }

    /// Автозаголовок: первая строка вопроса, trimmed, ≤60 символов; после
    /// первого вопроса заголовок не меняется (второй вопрос его не перезаписывает).
    @Test func autoTitleFromFirstQuestion() {
        #expect(AgentChatModel.autoTitle(from: "Найди встречи по слову прайсинг") == "Найди встречи по слову прайсинг")
        // Многострочный вопрос — первая содержательная строка.
        #expect(AgentChatModel.autoTitle(from: "  Первый вопрос\nвторой строки details") == "Первый вопрос")
        // Длинный — обрезка до 60 символов с многоточием.
        let long = String(repeating: "в", count: 80)
        let title = AgentChatModel.autoTitle(from: long)
        #expect(title.count == AgentChatModel.maxTitleLength + 1) // + «…»
        #expect(title.hasSuffix("…"))
        #expect(title.dropLast() == String(repeating: "в", count: AgentChatModel.maxTitleLength))
        // Пустой вопрос заголовка не задаёт.
        #expect(AgentChatModel.autoTitle(from: "   ") == "Новый чат")

        // Пограничная длина ровно 60 — без многоточия.
        let exact = String(repeating: "б", count: AgentChatModel.maxTitleLength)
        #expect(AgentChatModel.autoTitle(from: exact) == exact)
    }

    /// Второй вопрос сессии не перезаписывает уже выставленный автозаголовок.
    @Test func secondQuestionDoesNotRewriteTitle() async throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let model = AgentChatModel(library: f.library, stepDelay: .zero, store: f.store)
        model.draft = "Первый заголовок"
        model.send()
        try await AgentChatTests.waitIdle(model)

        model.draft = "Совсем другой длинный вопрос, который мог бы стать заголовком"
        model.send()
        try await AgentChatTests.waitIdle(model)

        #expect(model.sessionTitle == "Первый заголовок")
        let loaded = try #require(f.store.load(id: model.sessionID))
        #expect(loaded.title == "Первый заголовок")
    }

    // MARK: - Stale-append из отменённого потока (ревью #127)

    /// «Новый чат» во время стриминга: отмена задачи попадает в окно pause()
    /// (Task.sleep глотает CancellationError), но ни один последующий append
    /// не должен утечь в новый поток и в файл новой сессии; файл старой
    /// сессии не перезаписывается.
    @Test func newSessionDuringStreamingDoesNotLeakStaleAppends() async throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        // Реальная задержка шагов: append'ы идут с паузами, как в UI.
        let model = AgentChatModel(library: f.library, stepDelay: .milliseconds(80), store: f.store)
        model.draft = "Вопрос во время стриминга"
        model.send()
        // Середина потока: narration уже добавлен (t≈0), шаг — на паузе до ≈80 мс.
        try await Task.sleep(for: .milliseconds(50))

        let oldID = model.sessionID
        let oldURL = f.storeRoot.appendingPathComponent("\(oldID.uuidString).json")
        let oldData = try Data(contentsOf: oldURL)

        model.startNewSession()
        #expect(model.items.isEmpty)

        // Даём отменённой задаче проснуться и «дополнить бы поток»,
        // если защита сломана.
        try await Task.sleep(for: .milliseconds(400))

        // В новом потоке нет чужих строк, новый файл не создан.
        #expect(model.items.isEmpty)
        #expect(model.sessionID != oldID)
        #expect(model.sessionTitle == nil)
        #expect(f.store.load(id: model.sessionID) == nil)
        // Файл старой сессии не перезаписан побайтово.
        #expect(try Data(contentsOf: oldURL) == oldData)
    }

    /// Переключение на историческую сессию во время стриминга: сохранённый
    /// поток и файл истории не перезаписываются append'ами отменённого потока.
    @Test func openSessionDuringStreamingDoesNotRewriteHistory() async throws {
        let f = try AgentSessionsFixture()
        defer { f.cleanup() }

        let model = AgentChatModel(library: f.library, stepDelay: .zero, store: f.store)
        model.draft = "Завершённый вопрос"
        model.send()
        try await AgentChatTests.waitIdle(model)
        let historyID = model.sessionID
        let historyItems = model.items
        let historyURL = f.storeRoot.appendingPathComponent("\(historyID.uuidString).json")
        let historyData = try Data(contentsOf: historyURL)

        model.startNewSession()
        model.draft = "Вопрос с долгим стримингом"
        model.send()
        try await Task.sleep(for: .milliseconds(50))
        // Переключение посреди стриминга.
        model.openSession(id: historyID)
        #expect(model.items == historyItems)

        try await Task.sleep(for: .milliseconds(400))
        // Исторический поток не изменился ни в памяти, ни на диске.
        #expect(model.items == historyItems)
        #expect(model.sessionID == historyID)
        #expect(try Data(contentsOf: historyURL) == historyData)
        // Стримящаяся сессия не потеряна: её файл существует (append'ы в неё
        // не пишутся, но сохранённое до переключения — на месте).
        #expect(f.store.summaries().count == 2)
    }
}
