import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct MeetingProcessorTests {
    /// Держатель ссылки на процессор: замыкание захватывает `let holder`, а мы
    /// присваиваем `holder.proc` после init — так нет «mutated after capture».
    private final class Holder { var proc: MeetingProcessor? }

    @Test func reprocess_marksProcessingDuringRun_thenClears() async {
        var midRunContains: Bool?
        let holder = Holder()
        let proc = MeetingProcessor(work: { _ in
            midRunContains = holder.proc?.processing.contains("m1")
        })
        holder.proc = proc
        #expect(proc.processing.isEmpty)
        await proc.reprocess(id: "m1", folder: URL(fileURLWithPath: "/tmp/m1"))
        #expect(midRunContains == true)
        #expect(proc.processing.isEmpty)
    }

    @Test func reprocess_ignoresDuplicateForSameId() async {
        var callCount = 0
        let holder = Holder()
        let proc = MeetingProcessor(work: { _ in
            callCount += 1
            await holder.proc?.reprocess(id: "m1", folder: URL(fileURLWithPath: "/tmp/m1"))
        })
        holder.proc = proc
        await proc.reprocess(id: "m1", folder: URL(fileURLWithPath: "/tmp/m1"))
        #expect(callCount == 1)
    }
}

extension MeetingProcessorTests {
    struct OKCompleter: ChatCompleter {
        nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
            "{\"title\":\"Ручной заголовок\",\"summary\":\"С.\",\"actionPoints\":[]}"
        }
    }

    struct FailCompleter: ChatCompleter {
        nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
            throw LLMError.http(status: 500, body: "boom")
        }
    }

    @Test func regenerateInsights_writesInsightsAndTitle() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = MeetingMeta(id: dir.lastPathComponent, source: "kontur.talk",
            startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 600),
            durationSeconds: 600, status: .ready, asrModel: "gigaam-v3")
        try meta.write(to: dir.appendingPathComponent("meta.json"))
        let tr = Transcript(meetingId: meta.id, asrModel: "gigaam-v3",
            segments: [TranscriptSegment(start: 0, end: 1, speaker: .me, text: "привет")])
        try TranscriptMerger.renderJSON(tr).write(to: dir.appendingPathComponent("transcript.json"))

        let proc = MeetingProcessor()
        let gen = InsightsGenerator(client: OKCompleter(), model: "m")
        await proc.regenerateInsights(id: meta.id, folder: dir, generator: gen)

        let updated = try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(updated.title == "Ручной заголовок")
        #expect(updated.status == .ready)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("insights.json").path))
        #expect(proc.processing.isEmpty)
    }

    @Test func regenerateInsights_generatorFailureKeepsReadyNoInsights() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = MeetingMeta(id: dir.lastPathComponent, source: "kontur.talk",
            startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 600),
            durationSeconds: 600, status: .ready, asrModel: "gigaam-v3")
        try meta.write(to: dir.appendingPathComponent("meta.json"))
        let tr = Transcript(meetingId: meta.id, asrModel: "gigaam-v3",
            segments: [TranscriptSegment(start: 0, end: 1, speaker: .me, text: "привет")])
        try TranscriptMerger.renderJSON(tr).write(to: dir.appendingPathComponent("transcript.json"))

        let proc = MeetingProcessor()
        let gen = InsightsGenerator(client: FailCompleter(), model: "m")
        await proc.regenerateInsights(id: meta.id, folder: dir, generator: gen)

        let updated = try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(updated.status == .ready)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("insights.json").path))
        #expect(proc.insightsProcessing.isEmpty)
    }
}
