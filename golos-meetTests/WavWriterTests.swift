import Testing
import Foundation
@testable import golos_meet

@Suite struct WavWriterTests {
    @Test func writesValidWavHeaderAndSamples() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavwriter-\(UUID().uuidString).wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 1)
        // 100 сэмплов Int16 = 200 байт
        var pcm = Data()
        for i in 0..<100 { var s = Int16(i); pcm.append(Data(bytes: &s, count: 2)) }
        await writer.append(pcm)
        try await writer.finalize()

        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 44 + 200)                       // header + data
        #expect(bytes.prefix(4) == Data("RIFF".utf8))
        #expect(bytes[8..<12] == Data("WAVE".utf8))
        // sampleRate (offset 24, LE UInt32) == 16000
        let sr = bytes[24..<28].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        #expect(sr == 16_000)
        // data chunk size (offset 40, LE UInt32) == 200
        let dataSize = bytes[40..<44].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        #expect(dataSize == 200)
        try? FileManager.default.removeItem(at: url)
    }
}
