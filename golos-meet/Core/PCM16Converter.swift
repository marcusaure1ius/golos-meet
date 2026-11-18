import AVFoundation

/// Общая конвертация PCM в целевой формат записи (16kHz mono Int16 LE) для обеих дорожек.
/// Централизует хитрый паттерн `AVAudioConverter`, чтобы он не разъезжался между Mic и System.
nonisolated enum PCM16Converter {
    /// Целевой формат файлов дорожек: 16kHz mono Int16 LE.
    static var targetFormat: AVAudioFormat { AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )! }

    /// Конвертирует один входной буфер в Int16 LE PCM `Data` через переданный конвертер.
    ///
    /// Паттерн «один буфер → noDataNow»: конвертер живёт между вызовами (`.endOfStream` после
    /// первого input заблокировал бы все следующие). При downsample малых буферов (system audio
    /// ~960 кадров) конвертер часто отдаёт уже готовый выход со статусом `.inputRanDry`, а не
    /// `.haveData` — поэтому пишем по факту `frameLength > 0`; провал только при `.error`.
    static func int16Data(from inBuf: AVAudioPCMBuffer, using converter: AVAudioConverter) -> Data? {
        let target = converter.outputFormat
        let ratio = target.sampleRate / inBuf.format.sampleRate
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 32
        ) else { return nil }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuf, error: &error, withInputFrom: { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            consumed = true
            return inBuf
        })
        if status == .error { return nil }
        let frameCount = Int(outBuf.frameLength)
        if frameCount == 0 { return Data() } // Resampler buffering is not a capture failure.
        guard let int16Ptr = outBuf.int16ChannelData?[0] else { return nil }
        return Data(bytes: int16Ptr, count: frameCount * 2)
    }
}
