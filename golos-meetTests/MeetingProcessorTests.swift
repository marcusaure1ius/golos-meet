import Testing
import Foundation
@testable import golos_meet

/// Ворота: работа воркера блокируется, пока тест не откроет.
@MainActor
private final class Gate {
    private var conts: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { conts.append($0) }
    }
    func open() {
        opened = true
        conts.forEach { $0.resume() }
        conts.removeAll()
    }
}

@MainActor
@Suite struct MeetingProcessorTests {
    private func folder(_ id: String) -> URL { URL(fileURLWithPath: "/tmp/\(id)") }

    @Test func fifo_runsJobsOneByOneInOrder() async {
        var order: [String] = []
        let proc = MeetingProcessor(
            processWork: { url, _ in order.append("p:\(url.lastPathComponent)") },
            insightsWork: { id, _ in order.append("i:\(id)") })
        proc.enqueue(.process(deleteShortAudio: true), id: "a", folder: folder("a"))
        proc.enqueue(.insights, id: "b", folder: folder("b"))
        proc.enqueue(.process(deleteShortAudio: false), id: "c", folder: folder("c"))
        await proc.enqueueAndWait(.process(deleteShortAudio: false), id: "c", folder: folder("c"))
        #expect(order == ["p:a", "i:b", "p:c"])
        #expect(proc.activeJob == nil)
        #expect(proc.queuedJobs.isEmpty)
        #expect(proc.completedJobsCount == 3)
    }

    @Test func dedupe_sameKindSameMeeting_ignored() async {
        let gate = Gate()
        var calls = 0
        let proc = MeetingProcessor(
            processWork: { _, _ in calls += 1; await gate.wait() },
            insightsWork: { _, _ in })
        proc.enqueue(.process(deleteShortAudio: true), id: "m", folder: folder("m"))
        while proc.activeJob == nil { await Task.yield() }   // воркер подхватил первую
        proc.enqueue(.process(deleteShortAudio: false), id: "m", folder: folder("m"))  // дубликат (конфиг не различает)
        #expect(proc.queuedJobs.isEmpty)   // первая активна, вторая срезана
        gate.open()
        await proc.enqueueAndWait(.process(deleteShortAudio: true), id: "m", folder: folder("m"))
        #expect(calls == 1)
    }

    @Test func dedupe_processSupersedesQueuedInsights() async {
        let gate = Gate()
        var order: [String] = []
        let proc = MeetingProcessor(
            processWork: { url, _ in order.append("p:\(url.lastPathComponent)"); if url.lastPathComponent == "block" { await gate.wait() } },
            insightsWork: { id, _ in order.append("i:\(id)") })
        proc.enqueue(.process(deleteShortAudio: true), id: "block", folder: folder("block"))  // занимает воркер
        while proc.activeJob == nil { await Task.yield() }
        proc.enqueue(.insights, id: "m", folder: folder("m"))
        proc.enqueue(.process(deleteShortAudio: true), id: "m", folder: folder("m"))          // правило 1: вытесняет insights
        #expect(proc.queuedJobs.count == 1)
        #expect(proc.queuedJobs.first?.kind == .process(deleteShortAudio: true))
        gate.open()
        await proc.enqueueAndWait(.process(deleteShortAudio: true), id: "m", folder: folder("m"))
        #expect(order == ["p:block", "p:m"])
    }

    @Test func dedupe_insightsIgnoredWhenProcessPending() async {
        let gate = Gate()
        var insightsCalls = 0
        let proc = MeetingProcessor(
            processWork: { _, _ in await gate.wait() },
            insightsWork: { _, _ in insightsCalls += 1 })
        proc.enqueue(.process(deleteShortAudio: true), id: "m", folder: folder("m"))  // активна
        while proc.activeJob == nil { await Task.yield() }
        proc.enqueue(.insights, id: "m", folder: folder("m"))                          // правило 2: игнор
        #expect(proc.queuedJobs.isEmpty)
        gate.open()
        await proc.enqueueAndWait(.process(deleteShortAudio: true), id: "m", folder: folder("m"))
        #expect(insightsCalls == 0)
    }

    @Test func state_processingAndQueuedAndBanner() async {
        let gate = Gate()
        let proc = MeetingProcessor(
            processWork: { _, _ in await gate.wait() },
            insightsWork: { _, _ in await gate.wait() })
        proc.enqueue(.process(deleteShortAudio: true), id: "a", folder: folder("a"))
        proc.enqueue(.process(deleteShortAudio: true), id: "b", folder: folder("b"))
        proc.enqueue(.insights, id: "c", folder: folder("c"))
        // даём воркеру подхватить первую задачу
        while proc.activeJob == nil { await Task.yield() }
        #expect(proc.activeJob?.meetingId == "a")
        #expect(proc.processing == ["a", "b"])
        #expect(proc.insightsProcessing == ["c"])
        #expect(proc.isQueued("b"))
        #expect(!proc.isQueued("a"))          // активная — не «в очереди»
        #expect(proc.busyMeetingsCount == 3)
        gate.open()
        await proc.enqueueAndWait(.insights, id: "c", folder: folder("c"))
        #expect(proc.busyMeetingsCount == 0)
    }

    @Test func enqueueAndWait_dedupedInsights_waitsForProcess() async {
        let gate = Gate()
        var order: [String] = []
        let proc = MeetingProcessor(
            processWork: { url, _ in await gate.wait(); order.append("p:\(url.lastPathComponent)") },
            insightsWork: { id, _ in order.append("i:\(id)") })
        proc.enqueue(.process(deleteShortAudio: true), id: "m", folder: folder("m"))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            gate.open()
        }
        await proc.enqueueAndWait(.insights, id: "m", folder: folder("m"))  // срезана правилом 2 → ждёт process
        #expect(order == ["p:m"])
    }
}

// Тесты логики инсайтов (бывший regenerateInsights) — против runInsights напрямую.
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

    private func makeMeetingDir(status: MeetingStatus) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-ins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = MeetingMeta(id: dir.lastPathComponent, source: "kontur.talk",
            startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 600),
            durationSeconds: 600, status: status, asrModel: "gigaam-v3")
        try meta.write(to: dir.appendingPathComponent("meta.json"))
        let tr = Transcript(meetingId: meta.id, asrModel: "gigaam-v3",
            segments: [TranscriptSegment(start: 0, end: 1, speaker: .me, text: "привет")])
        try TranscriptMerger.renderJSON(tr).write(to: dir.appendingPathComponent("transcript.json"))
        return dir
    }

    @Test func runInsights_writesInsightsAndTitle() async throws {
        let dir = try makeMeetingDir(status: .ready)
        let gen = InsightsGenerator(client: OKCompleter(), model: "m")
        await MeetingProcessor.runInsights(id: dir.lastPathComponent, folder: dir, generator: gen)
        let updated = try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(updated.title == "Ручной заголовок")
        #expect(updated.status == .ready)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("insights.json").path))
    }

    @Test func runInsights_generatorFailureKeepsReadyNoInsights() async throws {
        let dir = try makeMeetingDir(status: .ready)
        let gen = InsightsGenerator(client: FailCompleter(), model: "m")
        await MeetingProcessor.runInsights(id: dir.lastPathComponent, folder: dir, generator: gen)
        let updated = try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(updated.status == .ready)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("insights.json").path))
    }

    /// Регрессия I-1: если пользователь успел вручную переименовать встречу (titleManual=true
    /// на диске) до/во время регенерации инсайтов, финальная запись meta не должна затирать
    /// ручной заголовок заголовком из LLM — при этом insights.json всё равно пишется.
    @Test func runInsights_regeneration_doesNotOverwriteManualTitle() async throws {
        let dir = try makeMeetingDir(status: .ready)
        let metaURL = dir.appendingPathComponent("meta.json")
        var meta = try MeetingMeta.decoded(Data(contentsOf: metaURL))
        meta.title = "Ручной"
        meta.titleManual = true
        try meta.write(to: metaURL)

        let gen = InsightsGenerator(client: OKCompleter(), model: "m")   // вернул бы «Ручной заголовок»
        await MeetingProcessor.runInsights(id: dir.lastPathComponent, folder: dir, generator: gen)

        let updated = try MeetingMeta.decoded(Data(contentsOf: metaURL))
        #expect(updated.title == "Ручной")
        #expect(updated.titleManual == true)
        #expect(updated.status == .ready)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("insights.json").path))
    }
}
