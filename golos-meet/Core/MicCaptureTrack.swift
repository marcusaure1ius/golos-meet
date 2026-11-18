import AVFoundation
import CoreAudio

/// Backend readiness means AVAudioEngine successfully started, even when muted.
@MainActor
final class MicCaptureTrack: AudioTrack {
    var onFailure: (() -> Void)?
    private let engine = AVAudioEngine()
    private var sink: PCMWriteSink?
    private var installedTap = false
    private var configurationObserver: NSObjectProtocol?

    func start(into writer: WavWriter) async throws {
        guard sink == nil else { return }
        let failure: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.onFailure?() }
        }
        let sink = PCMWriteSink(writer: writer, onFailure: failure)
        self.sink = sink
        do {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let converter = AVAudioConverter(from: inputFormat, to: PCM16Converter.targetFormat) else {
                throw NSError(domain: "MicCaptureTrack", code: -1)
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buf, _ in
                guard let data = PCM16Converter.int16Data(from: buf, using: converter) else {
                    failure(); return
                }
                sink.append(data)
            }
            installedTap = true
            try engine.start()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.onFailure?() }
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        engine.stop()
        let old = sink
        sink = nil
        await old?.close()
    }
}
