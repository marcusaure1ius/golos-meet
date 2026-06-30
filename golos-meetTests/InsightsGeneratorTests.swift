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
}
