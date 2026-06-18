import Testing
import AVFoundation
@testable import golos_meet

@Suite struct PCM16ConverterTests {
    /// Регресс: малый буфер при downsample 48k→16k конвертер отдаёт со статусом .inputRanDry,
    /// а не .haveData. Раньше это терялось → пустой выход. Проверяем, что выход НЕ пустой.
    @Test func smallDownsampleBufferProducesOutput() throws {
        let srcFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let inBuf = try #require(AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 960))
        inBuf.frameLength = 960
        if let ch = inBuf.floatChannelData?[0] {
            for i in 0..<960 { ch[i] = sin(Float(i) * 0.1) }   // не полный ноль
        }
        let converter = try #require(AVAudioConverter(from: srcFormat, to: PCM16Converter.targetFormat))

        let data = try #require(PCM16Converter.int16Data(from: inBuf, using: converter))

        #expect(!data.isEmpty)                       // ключевой регресс
        #expect(data.count % 2 == 0)                 // Int16
        #expect(data.count >= 256 && data.count <= 768)  // 960 кадров @48k → ~320 @16k
    }
}
