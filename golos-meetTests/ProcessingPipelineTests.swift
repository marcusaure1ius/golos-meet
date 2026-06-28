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
        let jsonURL = dir.appendingPathComponent("transcript.json")
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        let tr = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: jsonURL))
        #expect(tr.segments.map(\.text) == ["привет", "да"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
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
        try make("done", .ready)

        StartupRecovery.resetStaleProcessing(root: root)

        let stuck = try MeetingMeta.decoded(Data(contentsOf:
            root.appendingPathComponent("stuck/meta.json")))
        let done = try MeetingMeta.decoded(Data(contentsOf:
            root.appendingPathComponent("done/meta.json")))
        #expect(stuck.status == .failed)   // зависший processing сброшен
        #expect(done.status == .ready)     // готовый не тронут
    }
}
