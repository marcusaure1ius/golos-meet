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
