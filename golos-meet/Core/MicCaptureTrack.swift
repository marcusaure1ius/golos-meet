import AVFoundation
import CoreAudio
import os

/// Захват микрофона → 16kHz mono Int16 LE PCM → чанки в `WavWriter`.
/// Адаптация `golos/Core/AudioCapture.swift`: без level/voice-processing/выбора устройства,
/// чанки идут не в AsyncStream, а напрямую в переданный writer.
final class MicCaptureTrack: AudioTrack {
    private let engine = AVAudioEngine()
    private var writer: WavWriter?
    private var isRunning = false

    func start(into writer: WavWriter) throws {
        guard !isRunning else { return }
        self.writer = writer

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: PCM16Converter.targetFormat) else {
            throw NSError(domain: "MicCaptureTrack", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "не удалось создать AVAudioConverter"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buf, _ in
            guard let self, let writer = self.writer,
                  let data = PCM16Converter.int16Data(from: buf, using: converter) else { return }
            Task { await writer.append(data) }
        }
        try engine.start()
        isRunning = true
        Log.recorder.info("MicCaptureTrack started; inputFmt=\(String(describing: inputFormat), privacy: .public)")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        writer = nil
        Log.recorder.info("MicCaptureTrack stopped")
    }
}
