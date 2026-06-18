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

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func start(into writer: WavWriter) throws {
        guard !isRunning else { return }
        self.writer = writer

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw NSError(domain: "MicCaptureTrack", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "не удалось создать AVAudioConverter"])
        }
        let targetFormat = Self.targetFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buf, _ in
            self?.process(inputBuffer: buf, converter: converter, targetFormat: targetFormat)
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

    private func process(
        inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(Double(inputBuffer.frameLength)
                * targetFormat.sampleRate / inputBuffer.format.sampleRate) + 32
        ) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuf, error: &error, withInputFrom: { _, outStatus in
            if consumed {
                // КРИТИЧНО: .noDataNow, НЕ .endOfStream — конвертер живёт между tap-буферами;
                // .endOfStream после первого input заблокировал бы все следующие convert().
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            consumed = true
            return inputBuffer
        })
        // КРИТИЧНО: при downsample конвертер часто отдаёт готовый выход со статусом
        // .inputRanDry (вход исчерпан), а не .haveData. Приём только .haveData терял ~10%
        // кадров → дорожка короче реального времени. Писать по факту frameLength > 0.
        if status == .error { return }

        let frameCount = Int(outBuf.frameLength)
        guard frameCount > 0, let int16Ptr = outBuf.int16ChannelData?[0] else { return }
        let data = Data(bytes: int16Ptr, count: frameCount * 2)
        if let writer { Task { await writer.append(data) } }
    }
}
