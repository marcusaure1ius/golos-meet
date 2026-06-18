import AVFoundation
import ScreenCaptureKit
import os

/// Захват системного звука (голоса участников Толка) через ScreenCaptureKit →
/// 16kHz mono Int16 LE PCM → чанки в `WavWriter`.
///
/// ⚠️ Путь захвата системного звука (ScreenCaptureKit vs Core Audio process tap) — открытый
/// вопрос arch.md §10; спайк его не закрыл. Здесь основной путь плана: SCStream + capturesAudio.
/// Требует разрешения Screen Recording. Если на живой встрече две дорожки одновременно не
/// поедут — переключить на Core Audio process tap (гейт ревью Task 2).
final class SystemAudioCaptureTrack: NSObject, AudioTrack, SCStreamOutput {
    private var stream: SCStream?
    private var writer: WavWriter?
    private var converter: AVAudioConverter?
    private let sampleQueue = DispatchQueue(label: "com.golos.meet.system-audio")

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func start(into writer: WavWriter) throws {
        self.writer = writer
        // Конфигурация ScreenCaptureKit асинхронна; стартуем в Task.
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                   onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    Log.recorder.error("SystemAudioCaptureTrack: дисплеи не найдены")
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                // Видео не нужно, но SCStream требует валидный размер — берём минимальный.
                config.width = 2
                config.height = 2

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
                try await stream.startCapture()
                self.stream = stream
                Log.recorder.info("SystemAudioCaptureTrack started")
            } catch {
                Log.recorder.error("SystemAudioCaptureTrack старт провалился: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        let s = stream
        stream = nil
        writer = nil
        Task {
            try? await s?.stopCapture()
            Log.recorder.info("SystemAudioCaptureTrack stopped")
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let writer,
              let formatDesc = sampleBuffer.formatDescription else { return }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let converter = self.converter ?? AVAudioConverter(from: sourceFormat, to: Self.targetFormat)
        guard let converter else { return }
        self.converter = converter

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                   bufferListNoCopy: audioBufferList.unsafePointer) else { return }
                let ratio = Self.targetFormat.sampleRate / sourceFormat.sampleRate
                guard let outBuf = AVAudioPCMBuffer(
                    pcmFormat: Self.targetFormat,
                    frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 32
                ) else { return }

                var error: NSError?
                var consumed = false
                let status = converter.convert(to: outBuf, error: &error, withInputFrom: { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow   // тот же критичный паттерн, что и в MicCaptureTrack
                        return nil
                    }
                    outStatus.pointee = .haveData
                    consumed = true
                    return inBuf
                })
                guard status == .haveData else { return }

                let frameCount = Int(outBuf.frameLength)
                guard frameCount > 0, let int16Ptr = outBuf.int16ChannelData?[0] else { return }
                let data = Data(bytes: int16Ptr, count: frameCount * 2)
                Task { await writer.append(data) }
            }
        } catch {
            Log.recorder.error("SystemAudioCaptureTrack convert failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
