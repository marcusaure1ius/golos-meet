import Testing
import Foundation
@testable import golos_meet

@Suite struct ProcessingPipelineTests {
    // MARK: helpers
    private func tempMeeting(duration: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // фейковые дорожки
        try Data([0x52]).write(to: dir.appendingPathComponent("mic.wav"))
        try Data([0x52]).write(to: dir.appendingPathComponent("system.wav"))
        let meta = MeetingMeta(id: dir.lastPathComponent, source: "kontur.talk",
                               startedAt: Date(timeIntervalSince1970: 0),
                               endedAt: Date(timeIntervalSince1970: TimeInterval(duration)),
                               durationSeconds: duration, status: .recording, asrModel: nil)
        try meta.write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }
    private func readMeta(_ dir: URL) throws -> MeetingMeta {
        try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json")))
    }

    final class StubASR: ASRClient {
        let perFile: [String: [TimedSegment]]
        let failing: Bool
        init(perFile: [String: [TimedSegment]] = [:], failing: Bool = false) {
            self.perFile = perFile; self.failing = failing
        }
        func transcribe(fileURL: URL) async throws -> [TimedSegment] {
            if failing { throw ASRError.transcribeFailed("boom") }
            return perFile[fileURL.lastPathComponent] ?? []
        }
    }

    @Test func shortMeetingIsDiscardedAndAudioDeleted() async throws {
        let dir = try tempMeeting(duration: 120)
        let p = ProcessingPipeline(asrFactory: { StubASR() })
        await p.process(folder: dir)
        let meta = try readMeta(dir)
        #expect(meta.status == .discarded)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.wav").path))
    }

    @Test func longMeetingProducesTranscriptAndReady() async throws {
        let dir = try tempMeeting(duration: 600)
        let stub = StubASR(perFile: [
            "mic.wav": [TimedSegment(start: 4, end: 9, text: "да")],
            "system.wav": [TimedSegment(start: 0, end: 4, text: "привет")],
        ])
        let p = ProcessingPipeline(asrFactory: { stub })
        await p.process(folder: dir)
        let meta = try readMeta(dir)
        #expect(meta.status == .ready)
        #expect(meta.asrModel == "gigaam-v3")   // дефолтный modelId
        let jsonURL = dir.appendingPathComponent("transcript.json")
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        let tr = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: jsonURL))
        #expect(tr.segments.map(\.text) == ["привет", "да"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
    }

    @Test func asrModelIsThreadedIntoMeta() async throws {
        let dir = try tempMeeting(duration: 600)
        let stub = StubASR(perFile: ["mic.wav": [TimedSegment(start: 0, end: 1, text: "x")]])
        let p = ProcessingPipeline(asrFactory: { stub }, modelId: "whisper-large-v3")
        await p.process(folder: dir)
        let meta = try readMeta(dir)
        #expect(meta.status == .ready)
        #expect(meta.asrModel == "whisper-large-v3")
        let tr = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        #expect(tr.asrModel == "whisper-large-v3")
    }

    @Test func asrFailureMarksFailedAndKeepsAudio() async throws {
        let dir = try tempMeeting(duration: 600)
        let p = ProcessingPipeline(asrFactory: { StubASR(failing: true) })
        await p.process(folder: dir)
        let meta = try readMeta(dir)
        #expect(meta.status == .failed)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.wav").path))
    }

    @Test func backfillModeKeepsShortAudio() async throws {
        let dir = try tempMeeting(duration: 120)
        let p = ProcessingPipeline(asrFactory: { StubASR() },
                                   config: .init(thresholdSeconds: 300, deleteShortAudio: false))
        await p.process(folder: dir)
        let meta = try readMeta(dir)
        // короткая в backfill: не discarded-с-удалением; аудио на месте; ASR успешен → ready
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(meta.status == .ready)
    }

    // MARK: — LLM insights tests (Task 8) — see extension below

    @Test func startupResetsProcessingToFailed() throws {
        // отдельный temp-root с двумя встречами: одна processing, одна ready
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func make(_ id: String, _ status: MeetingStatus) throws {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let m = MeetingMeta(id: id, source: "kontur.talk",
                                startedAt: Date(timeIntervalSince1970: 0),
                                endedAt: Date(timeIntervalSince1970: 600),
                                durationSeconds: 600, status: status, asrModel: nil)
            try m.write(to: dir.appendingPathComponent("meta.json"))
        }
        try make("stuck", .processing)
        try make("crashed", .recording)
        try make("done", .ready)
        try make("dropped", .discarded)

        StartupRecovery.resetStale(root: root)

        func status(_ id: String) throws -> MeetingStatus? {
            try MeetingMeta.decoded(Data(contentsOf:
                root.appendingPathComponent("\(id)/meta.json"))).status
        }
        #expect(try status("stuck") == .failed)      // зависший processing сброшен
        #expect(try status("crashed") == .failed)    // краш во время записи сброшен
        #expect(try status("done") == .ready)        // готовый не тронут
        #expect(try status("dropped") == .discarded) // отброшенный не тронут
    }
}

extension ProcessingPipelineTests {
    // Мок-completer прямо отдаёт готовый JSON инсайтов или бросает.
    struct OKCompleter: ChatCompleter {
        nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
            "{\"title\":\"Умный заголовок\",\"summary\":\"Кратко.\",\"actionPoints\":[{\"text\":\"Сделать\",\"owner\":null}]}"
        }
    }
    struct FailCompleter: ChatCompleter {
        nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
            throw LLMError.http(status: 500, body: "boom")
        }
    }

    @Test func generatesInsightsAndTitleAfterTranscript() async throws {
        let dir = try tempMeeting(duration: 600)
        let stub = StubASR(perFile: ["mic.wav": [TimedSegment(start: 0, end: 1, text: "привет")]])
        let gen = InsightsGenerator(client: OKCompleter(), model: "qwen/qwen3.6-flash")
        let p = ProcessingPipeline(asrFactory: { stub }, insightsGenerator: gen)
        await p.process(folder: dir)

        let meta = try readMeta(dir)
        #expect(meta.status == .ready)
        #expect(meta.title == "Умный заголовок")
        let insURL = dir.appendingPathComponent("insights.json")
        #expect(FileManager.default.fileExists(atPath: insURL.path))
        let ins = try MeetingInsights.decoded(Data(contentsOf: insURL))
        #expect(ins.actionPoints.first?.text == "Сделать")
    }

    @Test func llmFailureKeepsMeetingReadyWithoutInsights() async throws {
        let dir = try tempMeeting(duration: 600)
        let stub = StubASR(perFile: ["mic.wav": [TimedSegment(start: 0, end: 1, text: "привет")]])
        let gen = InsightsGenerator(client: FailCompleter(), model: "m")
        let p = ProcessingPipeline(asrFactory: { stub }, insightsGenerator: gen)
        await p.process(folder: dir)

        let meta = try readMeta(dir)
        #expect(meta.status == .ready)   // НЕ failed — транскрипт валиден
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("insights.json").path))
    }

    @Test func startupResetsSummarizingToReady() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-root-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("sum", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = MeetingMeta(id: "sum", source: "kontur.talk",
            startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 600),
            durationSeconds: 600, status: .summarizing, asrModel: "gigaam-v3")
        try m.write(to: dir.appendingPathComponent("meta.json"))

        StartupRecovery.resetStale(root: root)

        let status = try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json"))).status
        #expect(status == .ready)   // не failed: транскрипт уже есть, недоделан только LLM
    }
}
