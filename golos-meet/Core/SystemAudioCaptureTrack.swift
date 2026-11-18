import AVFoundation
import ScreenCaptureKit

@MainActor
protocol SystemAudioStream: AnyObject {
    func startCapture() async throws
    func stopCapture() async throws
}

extension SCStream: SystemAudioStream {}

@MainActor
struct SystemAudioCaptureSession {
    let stream: any SystemAudioStream
    var processGuard: TalkAudioProcessGuard? = nil
}

/// ScreenCaptureKit readiness is its completed startCapture, not scheduling a Task.
/// The consumed screen output drives the audio pipeline; video is discarded.
@MainActor
final class SystemAudioCaptureTrack: NSObject, AudioTrack, SCStreamOutput, SCStreamDelegate {
    var onFailure: (() -> Void)?
    private var stream: (any SystemAudioStream)?
    private var generation: UUID?
    private var output: SystemAudioOutput?
    private var processGuard: TalkAudioProcessGuard?
    private var sourceError: TalkAudioCaptureError?
    var failureMessage: String? { sourceError?.errorDescription }
    private let sampleQueue = DispatchQueue(label: "com.golos.meet.system-audio")
    private let videoQueue = DispatchQueue(label: "com.golos.meet.system-video")

    /// Tests inject only the stream backend; the real track still owns startup,
    /// stop error propagation and sink draining. The live factory is never called.
    private let makeStream: (@MainActor (SCStreamOutput, SCStreamOutput, SCStreamDelegate) async throws -> SystemAudioCaptureSession)?

    init(makeStream: (@MainActor (SCStreamOutput, SCStreamOutput, SCStreamDelegate) async throws -> SystemAudioCaptureSession)? = nil) {
        self.makeStream = makeStream
        super.init()
    }

    func start(into writer: WavWriter) async throws {
        let id = UUID()
        generation = id
        sourceError = nil
        let sink = PCMWriteSink(writer: writer) { [weak self] in
            Task { @MainActor [weak self] in self?.reportFailure() }
        }
        let output = SystemAudioOutput(sink: sink) { [weak self] in
            Task { @MainActor [weak self] in self?.reportFailure() }
        }
        self.output = output
        var startingStream: (any SystemAudioStream)?
        do {
            let session: SystemAudioCaptureSession
            if let makeStream { session = try await makeStream(output, self, self) }
            else { session = try await makeLiveStream(audioOutput: output) }
            startingStream = session.stream
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            self.processGuard = session.processGuard
            try session.processGuard?.validate()
            self.stream = session.stream
            try await session.stream.startCapture()
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            try session.processGuard?.start { [weak self] error in
                guard let self, self.generation == id else { return }
                self.sourceError = error
                self.onFailure?()
            }
        } catch {
            let startupError = error
            if let error = startupError as? TalkAudioCaptureError { sourceError = error }
            processGuard?.stop()
            processGuard = nil
            var cleanupError: Error?
            do { try await startingStream?.stopCapture() } catch { cleanupError = error }
            await sink.close()
            if generation == id { generation = nil; stream = nil; self.output = nil }
            throw cleanupError ?? startupError
        }
    }

    private func makeLiveStream(audioOutput: SCStreamOutput) async throws -> SystemAudioCaptureSession {
        // Accidental use of the default path in a unit test must not prompt TCC
        // or enumerate real screen content. Live checks require a separate host.
        guard !AppRuntime.isTestHost else { throw TalkAudioCaptureError.sourceUnavailable }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw TalkAudioCaptureError.sourceUnavailable }
        try Task.checkCancellation()
        let targets = try TalkAudioSelection.select(content.applications.map {
            TalkAudioProcess(processID: $0.processID, bundleIdentifier: $0.bundleIdentifier)
        })
        let pids = Set(targets.map(\.processID))
        let included = content.applications.filter { pids.contains($0.processID) }
        guard included.count == targets.count else { throw TalkAudioCaptureError.invalidProcesses }
        guard let display = content.displays.first else { throw TalkAudioCaptureError.noDisplay }
        // Explicit inclusion only. No window/title selection or all-system fallback.
        let filter = SCContentFilter(display: display, including: included, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        return SystemAudioCaptureSession(stream: stream, processGuard: TalkAudioProcessGuard(targets: targets))
    }

    func stop() async throws {
        generation = nil
        processGuard?.stop()
        processGuard = nil
        let oldStream = stream
        let oldOutput = output
        stream = nil
        output = nil
        var stopError: Error?
        do { try await oldStream?.stopCapture() } catch { stopError = error }
        // Always stop accepting buffers and drain, including when macOS refuses stop.
        await oldOutput?.sink.close()
        if let stopError { throw stopError }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, self.generation != nil else { return }
            self.reportFailure()
        }
    }

    private func reportFailure() {
        guard generation != nil else { return }
        // A stream callback can precede the next timer tick after a process exits.
        do { try processGuard?.validate() }
        catch { sourceError = (error as? TalkAudioCaptureError) ?? .sourceUnavailable }
        onFailure?()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        // Video is deliberately discarded; audio goes to the serial queue below.
    }
}

/// All converter access is confined to the stream's serial audio sampleQueue.
private nonisolated final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sink: PCMWriteSink
    private let onFailure: @Sendable () -> Void
    private var converter: AVAudioConverter?

    init(sink: PCMWriteSink, onFailure: @escaping @Sendable () -> Void) {
        self.sink = sink
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription else { return }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard let converter = converter ?? AVAudioConverter(from: sourceFormat, to: PCM16Converter.targetFormat) else {
            onFailure(); return
        }
        self.converter = converter
        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                    bufferListNoCopy: audioBufferList.unsafePointer),
                      let data = PCM16Converter.int16Data(from: buffer, using: converter) else {
                    onFailure(); return
                }
                sink.append(data)
            }
        } catch { onFailure() }
    }
}
