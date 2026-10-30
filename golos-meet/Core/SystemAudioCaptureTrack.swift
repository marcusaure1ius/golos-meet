import AVFoundation
import ScreenCaptureKit

/// ScreenCaptureKit readiness is its completed startCapture, not scheduling a Task.
/// The consumed screen output drives the audio pipeline; video is discarded.
@MainActor
final class SystemAudioCaptureTrack: NSObject, AudioTrack, SCStreamOutput, SCStreamDelegate {
    var onFailure: (() -> Void)?
    private var stream: SCStream?
    private var generation: UUID?
    private var output: SystemAudioOutput?
    private let sampleQueue = DispatchQueue(label: "com.golos.meet.system-audio")
    private let videoQueue = DispatchQueue(label: "com.golos.meet.system-video")

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
        var startingStream: SCStream?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            guard generation == id, let display = content.displays.first else {
                throw CancellationError()
            }
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
            startingStream = stream
            self.stream = stream
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try await stream.startCapture()
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
        } catch {
            try? await startingStream?.stopCapture()
            await sink.close()
            if generation == id { generation = nil; stream = nil; self.output = nil }
            throw error
        }
    }

    func stop() async {
        generation = nil
        let oldStream = stream
        let oldOutput = output
        stream = nil
        output = nil
        try? await oldStream?.stopCapture()
        await oldOutput?.sink.close()
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
