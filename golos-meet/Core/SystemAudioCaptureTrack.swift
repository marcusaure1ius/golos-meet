import AVFoundation
import ScreenCaptureKit
import os

/// Захват системного звука (голоса участников Толка) через ScreenCaptureKit → 16kHz mono
/// Int16 LE PCM → чанки в `WavWriter`. Требует разрешения Screen Recording.
///
/// macOS 15+: чистый audio-only SCStream не доставляет аудио-буферы (`didOutputSampleBuffer`
/// для `.audio` не зовётся), пока в стриме нет потребляемого `.screen`-output, который драйвит
/// пайплайн. Поэтому добавляем фиктивный видео-output на 1 fps и выбрасываем кадры.
final class SystemAudioCaptureTrack: NSObject, AudioTrack, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: WavWriter?
    private var converter: AVAudioConverter?
    private let sampleQueue = DispatchQueue(label: "com.golos.meet.system-audio")
    private let videoQueue = DispatchQueue(label: "com.golos.meet.system-video")

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
                // Видео не нужно, но без потребляемого .screen-output аудио-пайплайн macOS 15+
                // не качает буферы. Берём реальный размер дисплея и минимальный fps.
                config.width = display.width
                config.height = display.height
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps — кадры выбрасываем
                config.queueDepth = 5

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.videoQueue)
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

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.recorder.error("SystemAudioCaptureTrack stream остановлен с ошибкой: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Видео-кадры нужны только чтобы пайплайн качал аудио — выбрасываем.
        guard type == .audio, sampleBuffer.isValid,
              let writer,
              let formatDesc = sampleBuffer.formatDescription else { return }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let converter = self.converter ?? AVAudioConverter(from: sourceFormat, to: PCM16Converter.targetFormat)
        guard let converter else { return }
        self.converter = converter

        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                               bufferListNoCopy: audioBufferList.unsafePointer),
                  let data = PCM16Converter.int16Data(from: inBuf, using: converter) else { return }
            Task { await writer.append(data) }
        }
    }
}
