import Foundation
import SwiftUI
import AppKit
import CryptoKit
import Testing
@testable import golos_meet

/// Фикстура QA-архива для чат-оболочки «Агент»: синтетические встречи
/// во временном каталоге (рабочие данные пользователя не трогаются).
@MainActor
private struct AgentChatFixture {
    let root: URL
    let library: MeetingLibrary

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = MeetingLibrary(root: root)
    }

    /// Встреча с meta + транскриптом; при `insights: true` — ещё и конспект.
    @discardableResult
    func meeting(_ id: String,
                 title: String,
                 startedAt: Date = Date(timeIntervalSince1970: 1_763_000_000),
                 durationSeconds: Int = 1800,
                 transcript: [String],
                 insights: Bool = false) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = MeetingMeta(id: id, source: "talk", startedAt: startedAt,
                               endedAt: startedAt.addingTimeInterval(TimeInterval(durationSeconds)),
                               durationSeconds: durationSeconds, status: .ready,
                               asrModel: "gigaam-v3", title: title, schemaVersion: 1)
        try MeetingMeta.encoded(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        let segments = transcript.enumerated().map { index, text in
            TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 9),
                              speaker: index % 2 == 0 ? .me : .participants, text: text)
        }
        let transcriptData = try JSONEncoder().encode(Transcript(meetingId: id, asrModel: "gigaam-v3", segments: segments))
        try transcriptData.write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        if insights {
            let parsed = MeetingInsights(
                meetingId: id, llmModel: "fake-model",
                generatedAt: startedAt.addingTimeInterval(TimeInterval(durationSeconds)),
                title: title,
                summary: "Договорились про прайсинг: скидка 10% с ноября.",
                actionPoints: [ActionPoint(id: UUID(), text: "Отправить прайс клиенту", owner: "я")],
                schemaVersion: 1)
            try MeetingInsights.encoded(parsed).write(to: dir.appendingPathComponent("insights.json"), options: .atomic)
        }
        return dir
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Suite struct AgentChatTests {
    /// Отправка сообщения: лента содержит narration, шаги и финальный ответ.
    @Test func sendProducesNarrationStepsAndAnswerOnRealFixtureData() async throws {
        let f = try AgentChatFixture()
        try f.meeting("2026-11-05_10-00-00", title: "Прайсинг ноября",
                      transcript: ["Обсудили прайсинг и скидки", "Договорились о скидке"], insights: true)
        let model = AgentChatModel(library: f.library, stepDelay: .zero)
        model.draft = "найди встречи по слову прайсинг"
        model.send()
        try await AgentChatTests.waitIdle(model)
        #expect(!model.isThinking)
        #expect(model.items.contains { if case .narration = $0 { return true } else { return false } })
        #expect(model.items.contains { if case .toolSteps = $0 { return true } else { return false } })
        #expect(model.items.contains { if case .artifact(let a) = $0 { return a.kind == .meeting && a.meetingID == "2026-11-05_10-00-00" } else { return false } })
        #expect(model.items.contains { if case .agentMessage(_, let text, _) = $0 { return text.contains("Нашёл") } else { return false } })
        f.cleanup()
    }

    /// Вопрос про договорённости — карточка конспекта с action points из insights.json.
    @Test func summaryIntentProducesSummaryArtifactWithActionPoints() async throws {
        let f = try AgentChatFixture()
        try f.meeting("2026-11-05_10-00-00", title: "Прайсинг ноября",
                      transcript: ["Обсудили прайсинг"], insights: true)
        try f.meeting("2026-11-10_12-00-00", title: "Ретро",
                      startedAt: Date(timeIntervalSince1970: 1_763_100_000),
                      transcript: ["Обсудили ретроспективу"]) // свежее, но без конспекта
        let model = AgentChatModel(library: f.library, stepDelay: .zero)
        model.draft = "О чём договорились на последней встрече?"
        model.send()
        try await AgentChatTests.waitIdle(model)
        let artifact = model.items.compactMap { item -> AgentArtifact? in
            if case .artifact(let a) = item, a.kind == .summary { return a }
            return nil
        }.first
        let a = try #require(artifact)
        #expect(a.title == "Прайсинг ноября")
        #expect(a.points == ["Отправить прайс клиенту"])
        #expect(a.body.contains("прайсинг"))
        #expect(a.meetingID == "2026-11-05_10-00-00")
        f.cleanup()
    }

    /// Предложение проекта — детерминированная карточка по теме из запроса.
    @Test func projectIntentProducesProjectSuggestionCard() async throws {
        let f = try AgentChatFixture()
        try f.meeting("2026-11-05_10-00-00", title: "Прайсинг ноября",
                      transcript: ["Обсудили прайсинг и скидки"])
        try f.meeting("2026-11-06_10-00-00", title: "Прайсинг декабря",
                      startedAt: Date(timeIntervalSince1970: 1_763_050_000),
                      transcript: ["Вернулись к прайсингу"])
        let model = AgentChatModel(library: f.library, stepDelay: .zero)
        model.draft = "Предложи проект по теме прайсинг"
        model.send()
        try await AgentChatTests.waitIdle(model)
        let artifact = model.items.compactMap { item -> AgentArtifact? in
            if case .artifact(let a) = item, a.kind == .projectSuggestion { return a }
            return nil
        }.first
        let a = try #require(artifact)
        #expect(a.title.lowercased().contains("прайсинг"))
        #expect(a.points.count == 2)
        #expect(a.sourceLabel.contains("без изменений данных"))
        f.cleanup()
    }

    /// Пустой архив — честный ответ без выдуманных результатов (П8 SPEC.md).
    @Test func emptyArchiveGivesHonestNoDataAnswer() async throws {
        let f = try AgentChatFixture()
        let model = AgentChatModel(library: f.library, stepDelay: .zero)
        model.draft = "найди встречи"
        model.send()
        try await AgentChatTests.waitIdle(model)
        #expect(!model.items.contains { if case .artifact = $0 { return true } else { return false } })
        #expect(model.items.contains { if case .agentMessage(_, let text, _) = $0 { return text.contains("нет расшифрованных встреч") } else { return false } })
        f.cleanup()
    }

    /// Без совпадений — «ничего не нашлось», без карточек.
    @Test func noMatchesGivesHonestEmptyResult() async throws {
        let f = try AgentChatFixture()
        try f.meeting("2026-11-05_10-00-00", title: "Ретро", transcript: ["Обсудили ретроспективу"])
        let model = AgentChatModel(library: f.library, stepDelay: .zero)
        model.draft = "найди слово бухгалтерия"
        model.send()
        try await AgentChatTests.waitIdle(model)
        #expect(!model.items.contains { if case .artifact = $0 { return true } else { return false } })
        #expect(model.items.contains { if case .agentMessage(_, let text, _) = $0 { return text.contains("ничего не нашлось") } else { return false } })
        f.cleanup()
    }

    /// Повторная отправка останавливает предыдущий прогон и дописывает ленту.
    @Test func newSendAppendsAndKeepsHistory() async throws {
        let f = try AgentChatFixture()
        try f.meeting("2026-11-05_10-00-00", title: "Ретро", transcript: ["Обсудили прайсинг"])
        let model = AgentChatModel(library: f.library, stepDelay: .zero)
        model.draft = "найди прайсинг"
        model.send()
        try await AgentChatTests.waitIdle(model)
        let afterFirst = model.items.count
        model.draft = "о чём договорились"
        model.send()
        try await AgentChatTests.waitIdle(model)
        #expect(model.items.count > afterFirst)
        #expect(model.items.contains { if case .userMessage(_, let text, _) = $0 { return text == "найди прайсинг" } else { return false } })
        #expect(model.items.contains { if case .userMessage(_, let text, _) = $0 { return text == "о чём договорились" } else { return false } })
        f.cleanup()
    }

    /// Рендер экрана «Агент» по явному запросу (паттерн ProjectMemoryPanelTests).
    @Test func renderActualAgentChatStatesWhenExplicitlyRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_AGENT_CHAT"], !output.isEmpty else { return }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = try AgentChatFixture()
        try f.meeting("2026-11-05_10-00-00", title: "Прайсинг ноября",
                      transcript: ["Обсудили прайсинг и скидки", "Договорились о скидке 10%"], insights: true)
        try f.meeting("2026-11-06_12-00-00", title: "Прайсинг декабря",
                      startedAt: Date(timeIntervalSince1970: 1_763_090_000),
                      transcript: ["Вернулись к прайсингу"], insights: true)
        var manifest: [[String: Any]] = []

        func capture(_ name: String, model: AgentChatModel, width: Int = 760, height: Int = 620) throws {
            for dark in [false, true] {
                let content = AgentChatView(model: model)
                    .frame(width: CGFloat(width), height: CGFloat(height))
                    .environment(\.palette, dark ? Palette.dark : Palette.light)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let filename = name + (dark ? "-dark.png" : "-light.png")
                try data.write(to: root.appendingPathComponent(filename))
                manifest.append(["file": filename,
                                 "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                 "width": width,
                                 "height": height])
                window.contentView = nil
            }
        }

        // 1. Пустой экран с подсказками.
        let empty = AgentChatModel(library: f.library, stepDelay: .zero)
        try capture("empty", model: empty)

        // 2. Разговор: narration, шаги, карточки-артефакты, композер.
        let talk = AgentChatModel(library: f.library, stepDelay: .zero)
        talk.draft = "найди встречи по слову прайсинг"
        talk.send()
        try await AgentChatTests.waitIdle(talk)
        try capture("conversation", model: talk, height: 900)

        // 3. Работающий агент: narration и блок процесса в процессе ответа.
        let busy = AgentChatModel(library: f.library, stepDelay: .milliseconds(60))
        busy.draft = "о чём договорились"
        busy.send()
        try capture("working", model: busy, height: 700)
        try await AgentChatTests.waitIdle(busy)

        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("render-manifest.json"))
        #expect(manifest.count == 6)
        f.cleanup()
    }

    static func waitIdle(_ model: AgentChatModel) async throws {
        let limit = ContinuousClock.now + .seconds(8)
        while model.isThinking {
            guard ContinuousClock.now < limit else { throw NSError(domain: "agent-chat", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Сценарии согласия в чате (issue #94 W4): карточка → действие → состояние.
/// Политики per-project — в принятом слое (ProjectStore на временном пути),
/// тот же API, что использует панель памяти; рабочие данные не затрагиваются.
@MainActor
@Suite(.serialized)
struct AgentConsentTests {
    @MainActor private struct Fixture {
        let root: URL
        let store: ProjectStore
        let projects: ProjectLibrary
        let library: MeetingLibrary

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-consent-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
            projects = ProjectLibrary(store: store)
            library = MeetingLibrary(root: root)
        }

        /// Встреча с транскриптом из текстов сегментов.
        func meeting(_ id: String, title: String, segments: [String]) throws {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta = MeetingMeta(id: id, source: "talk", startedAt: Date(timeIntervalSince1970: 1_763_000_000),
                                   endedAt: Date(timeIntervalSince1970: 1_763_002_000),
                                   durationSeconds: 2000, status: .ready,
                                   asrModel: "gigaam-v3", title: title, schemaVersion: 1)
            try MeetingMeta.encoded(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            let parts = segments.enumerated().map { index, text in
                ["start": Double(index * 10), "end": Double(index * 10 + 9),
                 "speaker": index % 2 == 0 ? "me" : "participants", "text": text]
            }
            try JSONSerialization.data(withJSONObject: ["meetingId": id, "asrModel": "gigaam-v3", "segments": parts])
                .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func consentCard(_ model: AgentChatModel) -> AgentConsentRequest? {
        model.items.compactMap { item -> AgentConsentRequest? in
            if case .consent(let request) = item { return request }
            return nil
        }.first
    }

    /// «Свести память проекта X» → narration + карточка согласия; пустые
    /// сегменты (<5 симв.) в контекст не попадают (#93 P3); на «Разрешить эту
    /// часть» — состояние карточки меняется, политика проекта в accepted-хранилище
    /// не меняется (разовое согласие #37).
    @Test func consolidationShowsConsentCardAndApprovalKeepsStorePolicy() async throws {
        let f = try Fixture()
        let project = try await f.store.createProject(name: "Прайсинг")
        try await f.store.setCloudPolicy(.askEveryTime, for: project.id)
        try await f.store.assignMeeting("2026-11-05_10-00-00", to: [project.id])
        try f.meeting("2026-11-05_10-00-00", title: "Прайсинг ноября",
                      segments: ["Обсудили прайсинг и скидки", "а.", "  ", "Договорились о скидке 10%"])
        await f.projects.reload()

        let model = AgentChatModel(library: f.library, projects: f.projects, stepDelay: .zero)
        model.draft = "сведи память проекта прайсинг"
        model.send()
        try await AgentChatTests.waitIdle(model)

        let request = try #require(consentCard(model), "Ожидалась карточка согласия")
        #expect(request.state == .pending)
        #expect(request.projectID == project.id)
        #expect(request.projectName == "Прайсинг")
        #expect(request.recipient == "OpenRouter")
        #expect(request.sourceDateKnown == false)
        #expect(request.allowsOneTimeApproval == true)
        // Пустые реплики («а.», пробелы) отфильтрованы из контекста (#93 P3).
        #expect(request.fragmentCount == 2)
        #expect(request.fragments == ["Обсудили прайсинг и скидки", "Договорились о скидке 10%"])
        #expect(model.items.contains { if case .narration(_, let text) = $0 { return text.contains("нужно") } else { return false } })

        // Действие: «Разрешить эту часть».
        model.approveConsent(request.id)
        let approved = try #require(consentCard(model))
        #expect(approved.state == .approved)
        #expect(model.items.contains { if case .narration(_, let text) = $0 { return text.contains("не используется") } else { return false } })
        // Политика в принятом хранилище осталась «Спрашивать каждый раз»:
        // разовое согласие не превращается в постоянный допуск (#37).
        let snapshot = try await f.store.snapshot()
        #expect(snapshot.projects.first { $0.id == project.id }?.cloudPolicy == .askEveryTime)
        f.cleanup()
    }

    /// «Отменить» — карточка в состоянии отмены, ничего не отправлялось.
    @Test func cancelConsentMarksCardCancelled() async throws {
        let f = try Fixture()
        let project = try await f.store.createProject(name: "Ретро")
        try await f.store.setCloudPolicy(.askEveryTime, for: project.id)
        try await f.store.assignMeeting("2026-11-05_10-00-00", to: [project.id])
        try f.meeting("2026-11-05_10-00-00", title: "Ретро ноября", segments: ["Обсудили ретроспективу команды"])
        await f.projects.reload()

        let model = AgentChatModel(library: f.library, projects: f.projects, stepDelay: .zero)
        model.draft = "сведи память проекта ретро"
        model.send()
        try await AgentChatTests.waitIdle(model)
        let request = try #require(consentCard(model))
        model.cancelConsent(request.id)
        let cancelled = try #require(consentCard(model))
        #expect(cancelled.state == .cancelled)
        #expect(model.items.contains { if case .narration(_, let text) = $0 { return text.contains("не покинул устройство") } else { return false } })
        f.cleanup()
    }

    /// Политика «Только локально» — запрет владельца: разовое согласие
    /// невозможно, кнопка разрешения не предлагается, повторное решение
    /// в модель фиксирует denied (принятое поведение #35/#37).
    @Test func localOnlyPolicyDeniesOneTimeApproval() async throws {
        let f = try Fixture()
        let project = try await f.store.createProject(name: "Секретный")
        try await f.store.assignMeeting("2026-11-05_10-00-00", to: [project.id])
        try f.meeting("2026-11-05_10-00-00", title: "Внутренний разбор", segments: ["Обсудили внутренние документы"])
        await f.projects.reload()

        let model = AgentChatModel(library: f.library, projects: f.projects, stepDelay: .zero)
        model.draft = "сведи память проекта секретный"
        model.send()
        try await AgentChatTests.waitIdle(model)
        let request = try #require(consentCard(model))
        #expect(request.allowsOneTimeApproval == false)
        #expect(request.policyLabel == "Только на этом Mac")
        model.approveConsent(request.id)
        let denied = try #require(consentCard(model))
        #expect(denied.state == .denied)
        let snapshot = try await f.store.snapshot()
        #expect(snapshot.projects.first { $0.id == project.id }?.cloudPolicy == .localOnly)
        f.cleanup()
    }

    /// Политика «Разрешать выбранный контекст» — карточка согласия не нужна:
    /// честная пометка демо-режима и raw-контекст карточкой с раскрытием.
    @Test func allowSelectedContextPolicySkipsConsentCardAndShowsRawContext() async throws {
        let f = try Fixture()
        let project = try await f.store.createProject(name: "Запуск")
        try await f.store.setCloudPolicy(.allowSelectedContext, for: project.id)
        try await f.store.assignMeeting("2026-11-05_10-00-00", to: [project.id])
        try f.meeting("2026-11-05_10-00-00", title: "Запуск ноября", segments: ["Обсудили план запуска на ноябрь"])
        await f.projects.reload()

        let model = AgentChatModel(library: f.library, projects: f.projects, stepDelay: .zero)
        model.draft = "сведи память проекта запуск"
        model.send()
        try await AgentChatTests.waitIdle(model)
        #expect(consentCard(model) == nil)
        #expect(model.items.contains { if case .artifact(let a) = $0 { return a.kind == .rawContext && a.points.count == 1 } else { return false } })
        #expect(model.items.contains { if case .agentMessage(_, let text, _) = $0 { return text.contains("не выполняется") } else { return false } })
        f.cleanup()
    }

    /// Повреждённый transcript.json — честный сбой в потоке (.failure),
    /// никаких выдуманных фрагментов и отправок.
    @Test func corruptTranscriptProducesHonestFailure() async throws {
        let f = try Fixture()
        let project = try await f.store.createProject(name: "Битый")
        try await f.store.setCloudPolicy(.askEveryTime, for: project.id)
        try await f.store.assignMeeting("2026-11-05_10-00-00", to: [project.id])
        try f.meeting("2026-11-05_10-00-00", title: "Битая встреча", segments: ["Обсудили что-то важное"])
        // Портим расшифровку после создания встречи.
        try Data("{broken json".utf8).write(to: f.root.appendingPathComponent("2026-11-05_10-00-00", isDirectory: true)
            .appendingPathComponent("transcript.json"), options: .atomic)
        await f.projects.reload()

        let model = AgentChatModel(library: f.library, projects: f.projects, stepDelay: .zero)
        model.draft = "сведи память проекта битый"
        model.send()
        try await AgentChatTests.waitIdle(model)
        #expect(consentCard(model) == nil)
        #expect(model.items.contains { if case .failure(_, let text) = $0 { return text.contains("Не удалось прочитать") && text.contains("Ничего не отправлялось") } else { return false } })
        f.cleanup()
    }

    /// Проект без назначенных встреч — честный ответ без карточки.
    @Test func projectWithoutMeetingsGivesHonestAnswer() async throws {
        let f = try Fixture()
        _ = try await f.store.createProject(name: "Пустой")
        await f.projects.reload()
        try f.meeting("2026-11-05_10-00-00", title: "Ничья встреча", segments: ["Обсудили что-то"])

        let model = AgentChatModel(library: f.library, projects: f.projects, stepDelay: .zero)
        model.draft = "сведи память проекта пустой"
        model.send()
        try await AgentChatTests.waitIdle(model)
        #expect(consentCard(model) == nil)
        #expect(model.items.contains { if case .agentMessage(_, let text, _) = $0 { return text.contains("нет встреч") } else { return false } })
        f.cleanup()
    }

    /// Неизвестный проект — честный ответ со списком доступных проектов.
    @Test func unknownProjectGivesHonestAnswerWithAvailableNames() async throws {
        let f = try Fixture()
        _ = try await f.store.createProject(name: "Альфа")
        // Встреча в архиве нужна, чтобы сценарий дошёл до поиска проекта.
        try f.meeting("2026-11-05_10-00-00", title: "Обычная встреча", segments: ["Обсудили что-то"])
        await f.projects.reload()
        let model = AgentChatModel(library: f.library, projects: f.projects, stepDelay: .zero)
        model.draft = "сведи память проекта омега"
        model.send()
        try await AgentChatTests.waitIdle(model)
        #expect(consentCard(model) == nil)
        #expect(model.items.contains { if case .agentMessage(_, let text, _) = $0 { return text.contains("не нашёлся") && text.contains("«Альфа»") } else { return false } })
        f.cleanup()
    }

    /// Фильтр пустых сегментов (#93 P3): реплики короче 5 символов после
    /// trim не считаются содержательным фрагментом.
    @Test func presentableFragmentsFilterShortSegments() {
        #expect(AgentChatModel.presentableFragments(["а.", "да", "  ", "Прайсинг утвердили", " ок "]) == ["Прайсинг утвердили"])
        #expect(AgentChatModel.presentableFragments([]) == [])
    }

    /// Скролл-счётчик шагов учитывает добавление в существующий блок
    /// .toolSteps (P3 ревью #97): items.count при этом не меняется.
    @Test func totalToolStepsCountsStepsInsideExistingBlock() async throws {
        let model = AgentChatModel(library: MeetingLibrary(root: FileManager.default.temporaryDirectory), stepDelay: .zero)
        #expect(model.totalToolSteps == 0)
        await model.toolStepBlock(label: "Шаг 1", result: nil)
        #expect(model.totalToolSteps == 1)
        let countBefore = model.items.count
        await model.toolStepBlock(label: "Шаг 2", result: "ок")
        #expect(model.totalToolSteps == 2)
        #expect(model.items.count == countBefore, "шаг дописан в существующий блок")
    }
}
