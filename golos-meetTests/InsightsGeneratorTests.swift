import Testing
import Foundation
@testable import golos_meet

@Suite struct InsightsGeneratorTests {
    static func sampleTranscript() -> Transcript {
        Transcript(meetingId: "M", asrModel: "gigaam-v3", segments: [
            TranscriptSegment(start: 0, end: 4, speaker: .participants, text: "Когда релиз?"),
            TranscriptSegment(start: 4, end: 9, speaker: .me, text: "Перенесём бету на июль."),
        ])
    }

    @Test func dialogRendersSpeakerLabelsWithoutTimecodes() {
        let text = InsightsPrompt.dialog(from: Self.sampleTranscript())
        #expect(text.contains("участники: Когда релиз?"))
        #expect(text.contains("я: Перенесём бету на июль."))
        #expect(!text.contains("0.0"))   // без таймкодов
    }
}

/// Мок-клиент: отдаёт заранее заданный ответ или бросает.
struct StubCompleter: ChatCompleter {
    var reply: String = ""
    var error: Error? = nil
    var captured: (@Sendable ([ChatMessage]) -> Void)? = nil
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        captured?(messages)
        if let error { throw error }
        return reply
    }
}

extension InsightsGeneratorTests {
    @Test func parsesCleanJSONIntoInsights() async throws {
        let json = """
        {"title":"Релиз 2.0","summary":"Перенос беты.","actionPoints":[
          {"text":"Чейнджлог","owner":"Денис"},{"text":"Дата QA","owner":null}]}
        """
        let gen = InsightsGenerator(client: StubCompleter(reply: json), model: "qwen/qwen3.6-flash")
        let ins = try await gen.generate(from: Self.sampleTranscript(), meetingId: "M",
                                         now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(ins.title == "Релиз 2.0")
        #expect(ins.summary == "Перенос беты.")
        #expect(ins.actionPoints.map(\.text) == ["Чейнджлог", "Дата QA"])
        #expect(ins.actionPoints[0].owner == "Денис")
        #expect(ins.actionPoints[1].owner == nil)
        #expect(ins.meetingId == "M")
        #expect(ins.llmModel == "qwen/qwen3.6-flash")
        #expect(ins.schemaVersion == 1)
    }

    @Test func recoversJSONWrappedInMarkdownFence() async throws {
        let fenced = "Вот результат:\n```json\n{\"title\":\"X\",\"summary\":\"Y\",\"actionPoints\":[]}\n```\n"
        let gen = InsightsGenerator(client: StubCompleter(reply: fenced), model: "m")
        let ins = try await gen.generate(from: Self.sampleTranscript(), meetingId: "M", now: .now)
        #expect(ins.title == "X")
        #expect(ins.actionPoints.isEmpty)
    }

    @Test func parsesSnakeCaseActionPoints() async throws {
        // Реальное наблюдение: qwen/qwen3.6-flash через OpenRouter не соблюдает
        // json_schema — отдаёт `action_points` вместо `actionPoints` и `task`
        // вместо `text`. Парсер должен принимать оба варианта.
        let snake = """
        {"title":"Релиз","summary":"С.","action_points":[
          {"task":"Сделать","owner":"Денис"},{"task":"Проверить","owner":null}]}
        """
        let gen = InsightsGenerator(client: StubCompleter(reply: snake), model: "m")
        let ins = try await gen.generate(from: Self.sampleTranscript(), meetingId: "M", now: .now)
        #expect(ins.actionPoints.map(\.text) == ["Сделать", "Проверить"])
        #expect(ins.actionPoints[0].owner == "Денис")
        #expect(ins.actionPoints[1].owner == nil)
    }

    @Test func throwsDecodeOnGarbage() async throws {
        let gen = InsightsGenerator(client: StubCompleter(reply: "извините, не понял"), model: "m")
        await #expect(throws: LLMError.self) {
            _ = try await gen.generate(from: Self.sampleTranscript(), meetingId: "M", now: .now)
        }
    }

    @Test func emptyTranscriptSkipsNetworkAndThrows() async throws {
        var called = false
        let stub = StubCompleter(reply: "{}", captured: { _ in called = true })
        let gen = InsightsGenerator(client: stub, model: "m")
        let empty = Transcript(meetingId: "M", asrModel: "gigaam-v3", segments: [])
        await #expect(throws: LLMError.self) {
            _ = try await gen.generate(from: empty, meetingId: "M", now: .now)
        }
        #expect(called == false)   // сеть не дёргали
    }

    // MARK: Пост-фильтр дегенеративных повторов (issue #93)

    /// Синтетический аналог реального дефекта: модель выдаёт один пункт,
    /// разросшийся в ~15 повторов одной мысли, плюс дубликаты самого пункта.
    /// Фильтр должен превратить это в короткий чистый список (≤5 пунктов).
    @Test func degenerateRepeatsCollapseToCleanList() async throws {
        let core = "Отправить Юле список продуктов в личку к пятнице."
        let degenerate = Array(repeating: core, count: 12).joined(separator: " ")
        let json = """
        {"title":"Список продуктов","summary":"Обсудили состав.","actionPoints":[
          {"text":"\(degenerate)","owner":null},
          {"text":"\(core)","owner":"Денис"},
          {"text":"\(core)","owner":"Alice"},
          {"text":"\(core)","owner":null},
          {"text":"Подготовить отчёт по кластерам к пятнице.","owner":"Мария"}
        ]}
        """
        let gen = InsightsGenerator(client: StubCompleter(reply: json), model: "m")
        let ins = try await gen.generate(from: Self.sampleTranscript(), meetingId: "M", now: .now)
        #expect(ins.actionPoints.count == 2)
        #expect(ins.actionPoints[0].text == core)
        #expect(ins.actionPoints[0].owner == nil)   // owner первого вхождения сохранён
        #expect(ins.actionPoints[1].text == "Подготовить отчёт по кластерам к пятнице.")
        #expect(ins.actionPoints[1].owner == "Мария")
        #expect(ins.title == "Список продуктов")    // title/summary не тронуты
        #expect(ins.summary == "Обсудили состав.")
    }

    /// Дегенерация внутри одного пункта с разными (не буквальными) предложениями
    /// обрезается лимитом числа предложений и длины пункта.
    @Test func bloatedPointIsTruncatedBySentenceAndLengthLimits() {
        let nouns = ["продукты", "кластеры", "бюджет", "отчёт", "дизайн", "поиск", "импорт", "модели"]
        let sentences = (0..<8).map {
            "Шаг \($0): согласовать состав блока «\(nouns[$0])» и направить итог команде проекта."
        }
        let bloated = sentences.joined(separator: " ")
        let trimmed = InsightsGenerator.trimPointRepeats(bloated)
        #expect(InsightsGenerator.splitSentences(trimmed).count <= InsightsGenerator.maxSentencesPerPoint)
        #expect(trimmed.count <= InsightsGenerator.hardPointCap)
        // Первое предложение сохраняется как итоговая формулировка.
        #expect(trimmed.hasPrefix("Шаг 0:"))
        // Предложения за лимитом вырезаются целиком, а не сокращаются частично.
        #expect(!trimmed.contains("дизайн"))
        #expect(trimmed.contains("продукты"))
    }

    /// Разные договорённости не схлопываются порогом сходства.
    @Test func distinctPointsSurviveDeduplication() {
        let points: [(String, String?)] = [
            ("Отправить список продуктов Юле в личку.", nil),
            ("Подготовить отчёт по кластерам к пятнице.", "Мария"),
            ("Уточнить бюджет у финансов до конца месяца.", nil),
        ]
        let sanitized = InsightsGenerator.sanitizePoints(points)
        #expect(sanitized.count == 3)
        #expect(sanitized.map(\.0) == points.map(\.0))
        #expect(sanitized.map(\.1) == points.map(\.1))
    }

    /// Граничный случай: пустой список пунктов остаётся пустым.
    @Test func emptyActionPointsStaysEmpty() async throws {
        let json = "{\"title\":\"Т\",\"summary\":\"С\",\"actionPoints\":[]}"
        let gen = InsightsGenerator(client: StubCompleter(reply: json), model: "m")
        let ins = try await gen.generate(from: Self.sampleTranscript(), meetingId: "M", now: .now)
        #expect(ins.actionPoints.isEmpty)
        #expect(InsightsGenerator.sanitizePoints([]).isEmpty)
    }

    /// Граничный случай: один пункт с owner=null проходит без изменений.
    @Test func singlePointWithNullOwnerIsPreserved() async throws {
        let json = """
        {"title":"Т","summary":"С","actionPoints":[{"text":"Позвонить поставщику.","owner":null}]}
        """
        let gen = InsightsGenerator(client: StubCompleter(reply: json), model: "m")
        let ins = try await gen.generate(from: Self.sampleTranscript(), meetingId: "M", now: .now)
        #expect(ins.actionPoints.count == 1)
        #expect(ins.actionPoints[0].text == "Позвонить поставщику.")
        #expect(ins.actionPoints[0].owner == nil)
    }

    /// Число пунктов ограничено `maxPoints` даже при потоке уникальных задач.
    @Test func parseCapsPointCountAtMaxPoints() {
        let nouns = ["продукты", "кластеры", "бюджет", "отчёт", "дизайн", "поиск", "импорт", "модели", "бэкап"]
        let items = (0..<9).map {
            "{\"text\":\"Задача номер \($0) — проверить «\(nouns[$0])» до конца недели.\",\"owner\":null}"
        }
        let json = "{\"title\":\"Т\",\"summary\":\"С\",\"actionPoints\":[\(items.joined(separator: ","))]}"
        let parsed = InsightsGenerator.parse(json)
        #expect(parsed?.points.count == InsightsGenerator.maxPoints)
    }

    /// Предложение без терминатора и пунктуационные обрывки не ломают фильтр.
    @Test func trimPointRepeatsHandlesUnterminatedAndEmptySentences() {
        // Дубль без завершающей точки в конце текста.
        let text = "Отправить отчёт в личку к пятнице. Отправить отчёт в личку к пятнице"
        let trimmed = InsightsGenerator.trimPointRepeats(text)
        #expect(trimmed == "Отправить отчёт в личку к пятнице.")
        // Пункты без содержательных токенов («а.») дедуплицируются между собой,
        // осмысленный сосед не теряется.
        let sanitized = InsightsGenerator.sanitizePoints([("а.", nil), ("а.", nil), ("Позвонить поставщику.", nil)])
        #expect(sanitized.count == 2)
        #expect(sanitized[0].0 == "а.")
        #expect(sanitized[0].1 == nil)
    }
}
