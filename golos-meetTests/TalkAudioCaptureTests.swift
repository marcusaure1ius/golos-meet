import Foundation
import Testing
@testable import golos_meet

@MainActor
@Suite struct TalkAudioCaptureTests {
    private final class Backend: SystemAudioStream {
        var starts = 0
        var stops = 0
        var duringStart: (() -> Void)?
        func startCapture() async throws { starts += 1; duringStart?() }
        func stopCapture() async throws { stops += 1 }
    }
    private final class Mic: AudioTrack {
        var onFailure: (() -> Void)?
        var writer: WavWriter?
        func start(into writer: WavWriter) async throws { self.writer = writer }
        func stop() async {}
    }
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        #expect(predicate())
    }

    @Test func defaultPathIsBlockedInUnitTestHostBeforeScreenDiscovery() async throws {
        #expect(AppRuntime.isTestHost)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-live-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url)
        let track = SystemAudioCaptureTrack()
        await #expect(throws: TalkAudioCaptureError.sourceUnavailable) { try await track.start(into: writer) }
        try await track.stop()
        try await writer.finalize()
    }

    @Test(arguments: [TalkAudioCaptureError.nativeClientNotFound, .invalidProcesses, .sourceUnavailable, .noDisplay])
    func sourceErrorsDoNotStartFallbackOrPublishReady(error: TalkAudioCaptureError) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("talk-error-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = RecordingState()
        var sourceAttempts = 0
        var queued = 0
        let system = SystemAudioCaptureTrack(makeStream: { _, _, _ in
            sourceAttempts += 1
            throw error
        })
        let recorder = Recorder(enqueueProcessing: { _, _ in queued += 1 }, makeMicTrack: { Mic() },
                                makeSysTrack: { system },
                                makeFolder: { _, source in MeetingFolder(id: "synthetic", url: root, source: source) },
                                state: state)
        #expect(recorder.meetingStarted(at: Date(), manual: false))
        await waitUntil { !recorder.isRecording }
        #expect(sourceAttempts == 1)
        #expect(state.live == nil)
        #expect(state.phase == .failed(error.localizedDescription))
        #expect(queued == 0)
        let meta = try MeetingMeta.decoded(Data(contentsOf: root.appendingPathComponent("meta.json")))
        #expect(meta.status == .failed && meta.preserveAudio == true)
    }

    @Test(arguments: [false, true])
    func selectedProcessLossOrInspectionErrorFinalizesAndProtectsAudio(inspectionThrows: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("talk-loss-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = RecordingState()
        let main = TalkAudioProcess(processID: 10, bundleIdentifier: "kontur.talk")
        var sourceAlive = true
        let guarder = TalkAudioProcessGuard(targets: [main], inspect: { _ in
            if !sourceAlive && inspectionThrows { throw NSError(domain: "synthetic", code: 1) }
            return sourceAlive
        })
        let backend = Backend(), mic = Mic()
        let system = SystemAudioCaptureTrack(makeStream: { _, _, _ in
            SystemAudioCaptureSession(stream: backend, processGuard: guarder)
        })
        var queued = 0
        let date = Date()
        let recorder = Recorder(enqueueProcessing: { _, _ in queued += 1 }, makeMicTrack: { mic },
                                makeSysTrack: { system },
                                makeFolder: { _, source in MeetingFolder(id: "synthetic", url: root, source: source) },
                                state: state)
        #expect(recorder.meetingStarted(at: date, manual: false))
        await waitUntil { state.live != nil }
        #expect(backend.starts == 1)
        await mic.writer?.append(Data([7, 0]))
        guarder.poll() // Silence is irrelevant: a live process remains a valid source.
        #expect(state.phase == .recording)
        sourceAlive = false
        guarder.poll()
        await waitUntil { !recorder.isRecording }
        #expect(backend.stops > 0 && queued == 0)
        #expect(state.system == .failed)
        #expect(state.phase == .failed((inspectionThrows
                                       ? TalkAudioCaptureError.sourceUnavailable
                                       : TalkAudioCaptureError.processDisappeared).localizedDescription))
        let meta = try MeetingMeta.decoded(Data(contentsOf: root.appendingPathComponent("meta.json")))
        #expect(meta.status == .failed && meta.preserveAudio == true)
        #expect(try Data(contentsOf: root.appendingPathComponent("mic.wav")).count == 46)
        sourceAlive = true
        guarder.poll()
        #expect(state.live == nil && backend.starts == 1) // No automatic replacement/restart.
    }

    @Test func disappearanceWhileBackendStartsNeverPublishesReadiness() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talk-start-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url)
        let backend = Backend()
        var alive = true
        let guarder = TalkAudioProcessGuard(targets: [.init(processID: 10, bundleIdentifier: "kontur.talk")],
                                           inspect: { _ in alive })
        backend.duringStart = { alive = false }
        let track = SystemAudioCaptureTrack(makeStream: { _, _, _ in
            SystemAudioCaptureSession(stream: backend, processGuard: guarder)
        })
        await #expect(throws: TalkAudioCaptureError.processDisappeared) { try await track.start(into: writer) }
        #expect(backend.stops == 1)
        try await track.stop()
        try await writer.finalize()
    }

    @Test(arguments: [false, true])
    func invalidOrMissingSelectedSourcePreventsBackendStart(emptySelection: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talk-preflight-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url)
        let backend = Backend()
        let targets = emptySelection ? [] : [TalkAudioProcess(processID: 10, bundleIdentifier: "kontur.talk")]
        let guarder = TalkAudioProcessGuard(targets: targets, inspect: { _ in false })
        let track = SystemAudioCaptureTrack(makeStream: { _, _, _ in
            SystemAudioCaptureSession(stream: backend, processGuard: guarder)
        })
        await #expect(throws: emptySelection ? TalkAudioCaptureError.nativeClientNotFound : .processDisappeared) {
            try await track.start(into: writer)
        }
        #expect(backend.starts == 0 && backend.stops == 1)
        try await track.stop()
        try await writer.finalize()
    }
}
