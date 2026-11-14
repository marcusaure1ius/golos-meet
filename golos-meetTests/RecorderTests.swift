import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct RecorderTests {
    private final class FakeTrack: AudioTrack {
        var onFailure: (() -> Void)?
        var stopCount = 0
        var started = false
        var delayed = false
        var failing = false
        var failOnStop = false
        var writer: WavWriter?
        private var continuation: CheckedContinuation<Void, Never>?
        func start(into writer: WavWriter) async throws {
            started = true
            self.writer = writer
            if delayed { await withCheckedContinuation { continuation = $0 } }
            if failing { throw NSError(domain: "synthetic", code: 1) }
        }
        func releaseStart() { continuation?.resume(); continuation = nil }
        func stop() async {
            stopCount += 1
            if failOnStop && stopCount == 1 { onFailure?() }
        }
    }

    /// Exercises the actual SystemAudioCaptureTrack stop path, not onFailure.
    private final class FailingStopStream: SystemAudioStream {
        var started = false
        var stopCount = 0
        func startCapture() async throws { started = true }
        func stopCapture() async throws {
            stopCount += 1
            throw NSError(domain: "synthetic-stopCapture", code: 1)
        }
    }

    @MainActor private struct Fixture {
        let recorder: Recorder
        let root: URL
        let mic: FakeTrack
        let sys: FakeTrack
        let state: RecordingState
        let date = Date(timeIntervalSince1970: 1_000_000)
        var folder: URL { root.appendingPathComponent("synthetic") }
        func meta() throws -> MeetingMeta {
            try MeetingMeta.decoded(Data(contentsOf: folder.appendingPathComponent("meta.json")))
        }
    }

    private func fixture(timeout: Duration = .seconds(20), enqueued: @escaping (String, URL) -> Void = { _, _ in }) -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gm-rec-\(UUID())")
        let mic = FakeTrack(), sys = FakeTrack(), state = RecordingState()
        let rec = Recorder(enqueueProcessing: enqueued, makeMicTrack: { mic }, makeSysTrack: { sys },
                           makeFolder: { date, source in
                               let id = date == Date(timeIntervalSince1970: 1_000_000) ? "synthetic" : "retry"
                               return MeetingFolder(id: id, url: root.appendingPathComponent(id), source: source)
                           },
                           state: state, startupTimeout: timeout)
        return Fixture(recorder: rec, root: root, mic: mic, sys: sys, state: state)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        #expect(predicate())
    }

    @Test func publishesRecordingOnlyAfterBothBackendsAreReady() async throws {
        let f = fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.sys.delayed = true
        #expect(f.recorder.meetingStarted(at: f.date, manual: true))
        #expect(f.state.phase == .starting)
        #expect(f.state.live == nil)
        await waitUntil { f.sys.started }
        #expect(f.state.microphone == .ready)
        #expect(f.state.system == .waiting)
        #expect(f.state.live == nil)
        f.sys.releaseStart()
        await waitUntil { f.state.live != nil }
        #expect(f.state.phase == .recording)
        #expect(f.state.live?.isManual == true)
        #expect(try f.meta().preserveAudio == true)
        _ = await f.recorder.finalizeActive(endedAt: f.date.addingTimeInterval(90))
        #expect(f.state.phase == .idle)
    }

    @Test func finalizeDrainsStopsClosesMetaAndIsIdempotent() async throws {
        let f = fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.recorder.meetingStarted(at: f.date, manual: false))
        await waitUntil { f.state.live != nil }
        await f.mic.writer?.append(Data(repeating: 0, count: 320))
        let folder = await f.recorder.finalizeActive(endedAt: f.date.addingTimeInterval(90))
        #expect(folder != nil)
        #expect(!f.recorder.isRecording)
        #expect(f.mic.stopCount > 0 && f.sys.stopCount > 0)
        #expect(try f.meta().durationSeconds == 90)
        #expect(try f.meta().preserveAudio == false)
        let data = try Data(contentsOf: f.folder.appendingPathComponent("mic.wav"))
        #expect(data.count == 364)
        let second = await f.recorder.finalizeActive(endedAt: f.date.addingTimeInterval(120))
        #expect(second == nil)
        #expect(try f.meta().durationSeconds == 90)
    }

    @Test func partialStartFailureStopsBothTracksPreservesAudioAndAllowsManualRetry() async throws {
        let f = fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var failures = 0
        f.recorder.onCaptureFailure = { failures += 1 }
        f.sys.failing = true
        #expect(f.recorder.meetingStarted(at: f.date, manual: true))
        await waitUntil { !f.recorder.isRecording }
        #expect(f.state.live == nil)
        #expect(f.state.system == .failed)
        #expect(f.mic.stopCount > 0 && f.sys.stopCount > 0)
        #expect(failures == 1)
        #expect(try f.meta().status == .failed)
        #expect(try f.meta().preserveAudio == true)
        // A fresh attempt must not be blocked by the failed manual session.
        let detector = MeetingDetector()
        detector.captureFailed()
        f.sys.failing = false
        detector.delegate = f.recorder
        detector.forceStart(at: f.date.addingTimeInterval(120))
        await waitUntil { f.state.live != nil }
        #expect(f.state.live?.isManual == true)
        _ = await f.recorder.finalizeActive(endedAt: f.date.addingTimeInterval(150))
    }

    @Test func stopDuringStartWaitsForLateBackendAndDoesNotPublishRecording() async throws {
        let f = fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.sys.delayed = true
        #expect(f.recorder.meetingStarted(at: f.date, manual: true))
        await waitUntil { f.sys.started }
        let firstStop = Task { await f.recorder.finalizeActive(endedAt: f.date.addingTimeInterval(1)) }
        await waitUntil { f.sys.stopCount > 0 }
        let duplicate = Task { await f.recorder.finalizeActive(endedAt: f.date.addingTimeInterval(2)) }
        #expect(f.recorder.isRecording)
        #expect(!f.recorder.meetingStarted(at: f.date, manual: true))
        #expect(f.state.phase == .stopping)
        f.sys.releaseStart() // Deliberately ignores cancellation, like a late OS callback.
        #expect(await firstStop.value != nil)
        #expect(await duplicate.value == nil)
        #expect(f.state.live == nil)
        #expect(f.state.phase == .idle)
        #expect(f.sys.stopCount >= 2)
        #expect(try f.meta().preserveAudio == true)
    }

    @Test func backendFailureDuringRecordingFinalizesWithoutAutomaticProcessing() async throws {
        var queued = 0
        let f = fixture(enqueued: { _, _ in queued += 1 })
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.recorder.meetingStarted(at: f.date, manual: false))
        await waitUntil { f.state.live != nil }
        await f.sys.writer?.append(Data(repeating: 0, count: 320))
        f.sys.onFailure?()
        f.sys.onFailure?()
        await waitUntil { !f.recorder.isRecording }
        #expect(queued == 0)
        #expect(try f.meta().status == .failed)
        #expect(try f.meta().preserveAudio == true)
        #expect(try Data(contentsOf: f.folder.appendingPathComponent("system.wav")).count == 364)
    }

    @Test func shortManualRecordingEnqueuesWithPersistentProtection() async throws {
        var queued = 0
        let f = fixture(enqueued: { _, _ in queued += 1 })
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.recorder.meetingStarted(at: f.date, manual: true))
        await waitUntil { f.state.live != nil }
        f.recorder.meetingEnded(at: f.date.addingTimeInterval(3))
        await waitUntil { queued > 0 }
        #expect(queued == 1)
        #expect(try f.meta().preserveAudio == true)
        #expect(try f.meta().durationSeconds == 3)
    }

    @Test func startupTimeoutCannotBecomeLateSuccess() async throws {
        let f = fixture(timeout: .zero)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.mic.delayed = true
        #expect(f.recorder.meetingStarted(at: f.date, manual: true))
        await waitUntil { f.mic.stopCount > 0 }
        f.mic.releaseStart()
        await waitUntil { !f.recorder.isRecording }
        #expect(f.state.live == nil)
        #expect(try f.meta().status == .failed)
    }

    @Test func duplicateFolderCannotOverwritePreviousAudio() async throws {
        let f = fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.recorder.meetingStarted(at: f.date, manual: true))
        await waitUntil { f.state.live != nil }
        await f.mic.writer?.append(Data([7, 0]))
        _ = await f.recorder.finalizeActive(endedAt: f.date.addingTimeInterval(1))
        let data = try Data(contentsOf: f.folder.appendingPathComponent("mic.wav"))
        #expect(!f.recorder.meetingStarted(at: f.date, manual: true))
        #expect(try Data(contentsOf: f.folder.appendingPathComponent("mic.wav")) == data)
    }

    @Test func failureWhileDrainingKeepsProtectionAndFailureStatus() async throws {
        let f = fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.recorder.meetingStarted(at: f.date, manual: false))
        await waitUntil { f.state.live != nil }
        f.sys.failOnStop = true
        _ = await f.recorder.finalizeActive(endedAt: f.date.addingTimeInterval(3))
        #expect(try f.meta().preserveAudio == true)
        #expect(try f.meta().status == .failed)
        #expect(f.state.system == .failed)
    }

    @Test func systemTrackPropagatesBackendStopFailureBeforeMetadataAndQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stop-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FailingStopStream()
        let systemTrack = SystemAudioCaptureTrack(makeStream: { _, _, _ in SystemAudioCaptureSession(stream: backend) })
        let mic = FakeTrack()
        let state = RecordingState()
        var queued = 0
        let date = Date(timeIntervalSince1970: 1_000_000)
        let recorder = Recorder(enqueueProcessing: { _, _ in queued += 1 }, makeMicTrack: { mic },
                                makeSysTrack: { systemTrack },
                                makeFolder: { _, source in MeetingFolder(id: "synthetic", url: root, source: source) },
                                state: state)
        #expect(recorder.meetingStarted(at: date, manual: false))
        await waitUntil { state.live != nil }
        #expect(backend.started)
        await mic.writer?.append(Data([7, 0]))
        recorder.meetingEnded(at: date.addingTimeInterval(1))
        await waitUntil { !recorder.isRecording }
        let meta = try MeetingMeta.decoded(Data(contentsOf: root.appendingPathComponent("meta.json")))
        #expect(backend.stopCount > 0)
        #expect(meta.status == .failed)
        #expect(meta.preserveAudio == true)
        #expect(state.system == .failed)
        #expect(queued == 0)
        let pipeline = ProcessingPipeline(asrFactory: { ProcessingPipelineTests.StubASR() })
        await pipeline.process(folder: root)
        #expect(try Data(contentsOf: root.appendingPathComponent("mic.wav")).count == 46)
    }
}
