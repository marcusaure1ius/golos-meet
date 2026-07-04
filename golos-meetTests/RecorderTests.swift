import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite(.serialized) struct RecorderTests {
    private final class FakeTrack: AudioTrack {
        var stopped = false
        func start(into writer: WavWriter) throws {}
        func stop() { stopped = true }
    }

    private func makeRecorder(enqueued: @escaping (String, URL) -> Void)
        -> (Recorder, URL, FakeTrack, FakeTrack) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-rec-\(UUID().uuidString)", isDirectory: true)
        let mic = FakeTrack(), sys = FakeTrack()
        let rec = Recorder(
            enqueueProcessing: enqueued,
            makeMicTrack: { mic },
            makeSysTrack: { sys },
            makeFolder: { date, source in
                let id = ISO8601DateFormatter().string(from: date)
                return MeetingFolder(id: id, url: root.appendingPathComponent(id, isDirectory: true), source: source)
            })
        return (rec, root, mic, sys)
    }

    @Test func finalizeActive_closesMetaWithRealDuration_andIsIdempotent() async throws {
        let (rec, _, mic, sys) = makeRecorder(enqueued: { _, _ in })
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(rec.meetingStarted(at: start, manual: false))
        #expect(rec.isRecording)

        let folder = await rec.finalizeActive(endedAt: start.addingTimeInterval(90))
        #expect(folder != nil)
        #expect(!rec.isRecording)
        #expect(mic.stopped && sys.stopped)

        let meta = try MeetingMeta.decoded(Data(contentsOf: folder!.url.appendingPathComponent("meta.json")))
        #expect(meta.durationSeconds == 90)
        #expect(meta.status == .recording)

        // Идемпотентность: второй вызов (terminate вслед за meetingEnded) — nil, ничего не портит.
        let second = await rec.finalizeActive(endedAt: start.addingTimeInterval(120))
        #expect(second == nil)
        let metaAfter = try MeetingMeta.decoded(Data(contentsOf: folder!.url.appendingPathComponent("meta.json")))
        #expect(metaAfter.durationSeconds == 90)
    }

    @Test func meetingEnded_finalizesAndEnqueues() async {
        var enqueued: [(String, URL)] = []
        let (rec, _, _, _) = makeRecorder(enqueued: { id, url in enqueued.append((id, url)) })
        let start = Date(timeIntervalSince1970: 2_000_000)
        #expect(rec.meetingStarted(at: start, manual: false))
        rec.meetingEnded(at: start.addingTimeInterval(400))
        // meetingEnded финализирует в Task — дожидаемся.
        for _ in 0..<2000 where enqueued.isEmpty { await Task.yield() }
        #expect(enqueued.count == 1)
        #expect(!rec.isRecording)
    }

    @Test func meetingStarted_publishesLiveState_finalizeClears() async {
        RecordingState.shared.end()   // чистим синглтон на входе
        let (rec, _, _, _) = makeRecorder(enqueued: { _, _ in })
        let start = Date(timeIntervalSince1970: 3_000_000)
        #expect(rec.meetingStarted(at: start, manual: true))
        #expect(RecordingState.shared.live?.isManual == true)
        #expect(RecordingState.shared.live?.startedAt == start)
        _ = await rec.finalizeActive(endedAt: start.addingTimeInterval(60))
        #expect(RecordingState.shared.live == nil)
    }
}
