import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct WavRepairTests {
    /// Собирает WAV-файл: канонический 44-байтный заголовок + `dataBytes` нулей.
    /// `headerDataField` — что записано в поле data size (у осиротевших файлов там 0).
    private func makeWav(dataBytes: Int, headerDataField: UInt32,
                         sampleRate: UInt32 = 16_000) throws -> URL {
        var d = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let byteRate = sampleRate * 2   // mono, 16 бит
        d.append(Data("RIFF".utf8)); le32(36 &+ headerDataField); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(sampleRate); le32(byteRate); le16(2); le16(16)
        d.append(Data("data".utf8)); le32(headerDataField)
        d.append(Data(count: dataBytes))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavrepair-\(UUID().uuidString).wav")
        try d.write(to: url)
        return url
    }

    private func dataField(of url: URL) throws -> UInt32 {
        let d = try Data(contentsOf: url)
        return d.subdata(in: 40..<44).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    @Test func brokenHeader_isRepaired_durationComputed() throws {
        // 64 000 байт данных = 2 секунды при 16 кГц mono Int16; в заголовке 0.
        let url = try makeWav(dataBytes: 64_000, headerDataField: 0)
        let outcome = WavRepair.repairIfNeeded(at: url)
        #expect(outcome == WavRepair.Outcome(durationSeconds: 2, repaired: true))
        #expect(try dataField(of: url) == 64_000)
    }

    @Test func healthyFile_untouched() throws {
        let url = try makeWav(dataBytes: 32_000, headerDataField: 32_000)
        let before = try Data(contentsOf: url)
        let outcome = WavRepair.repairIfNeeded(at: url)
        #expect(outcome == WavRepair.Outcome(durationSeconds: 1, repaired: false))
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func stub_smallerThanHeader_isSkipped() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavrepair-stub-\(UUID().uuidString).wav")
        try Data("RIFF".utf8).write(to: url)
        #expect(WavRepair.repairIfNeeded(at: url) == nil)
    }

    @Test func missingFile_returnsNil() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav")
        #expect(WavRepair.repairIfNeeded(at: url) == nil)
    }

    @Test func notWav_returnsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavrepair-txt-\(UUID().uuidString).wav")
        try Data(repeating: 0x41, count: 100).write(to: url)
        #expect(WavRepair.repairIfNeeded(at: url) == nil)
    }
}
