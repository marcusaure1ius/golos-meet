import AVFoundation
import ScreenCaptureKit

@MainActor
protocol SystemAudioStream: AnyObject {
    func startCapture() async throws
    func stopCapture() async throws
}

extension SCStream: SystemAudioStream {}

/// ScreenCaptureKit readiness is its completed startCapture, not scheduling a Task.
/// The consumed screen output drives the audio pipeline; video is discarded.
@MainActor
final class SystemAudioCaptureTrack: NSObject, AudioTrack, SCStreamOutput, SCStreamDelegate {
    var onFailure: (() -> Void)?
    private var stream: (any SystemAudioStream)?
    private var generation: UUID?
    private var output: SystemAudioOutput?
    private let sampleQueue = DispatchQueue(label: "com.golos.meet.system-audio")
    private let videoQueue = DispatchQueue(label: "com.golos.meet.system-video")

    /// Tests inject only the stream backend; the real track still owns startup,
    /// stop error propagation and sink draining. The live factory is never called.
    private let makeStream: (@MainActor (SCStreamOutput, SCStreamOutput, SCStreamDelegate) async throws -> any SystemAudioStream)?

    init(makeStream: (@MainActor (SCStreamOutput, SCStreamOutput, SCStreamDelegate) async throws -> any SystemAudioStream)? = nil) {
        self.makeStream = makeStream
        super.init()
    }

    func start(into writer: WavWriter) async throws {
        let id = UUID()
        generation = id
        let sink = PCMWriteSink(writer: writer) { [weak self] in
            Task { @MainActor [weak self] in self?.onFailure?() }
        }
        let output = SystemAudioOutput(sink: sink) { [weak self] in
            Task { @MainActor [weak self] in self?.onFailure?() }
        }
        self.output = output
        var startingStream: (any SystemAudioStream)?
        do {
            let backend: any SystemAudioStream
            if let makeStream { backend = try await makeStream(output, self, self) }
            else { backend = try await makeLiveStream(audioOutput: output) }
            startingStream = backend
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            self.stream = backend
            try await backend.startCapture()
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
        } catch {
            let startupError = error
            var cleanupError: Error?
            do { try await startingStream?.stopCapture() } catch { cleanupError = error }
            await sink.close()
            if generation == id { generation = nil; stream = nil; self.output = nil }
            throw cleanupError ?? startupError
        }
    }

    private func makeLiveStream(audioOutput: SCStreamOutput) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard let display = content.displays.first else { throw CancellationError() }
        let filter = SCContentFilter(display: display, excludingWindows: [])
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
        return stream
    }

    func stop() async throws {
        generation = nil
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
            self.onFailure?()
        }
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
