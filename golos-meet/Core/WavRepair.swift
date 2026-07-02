import Foundation
import os

/// Ремонт WAV-файлов, осиротевших после краша: `WavWriter` дописывает размеры
/// в заголовок только в `finalize()`, поэтому у оборванной записи в заголовке
/// data size = 0, хотя данные в файле есть. Правим два поля заголовка in-place,
/// сами данные не читаем.
enum WavRepair {
    struct Outcome: Equatable {
        let durationSeconds: Int
        let repaired: Bool
    }

    private static let headerSize: UInt64 = 44

    /// Чинит заголовок, если задекларированный размер данных не совпадает с фактическим.
    /// Возвращает длительность по факту данных; nil — файла нет, он короче заголовка
    /// или это не WAV.
    @discardableResult
    static func repairIfNeeded(at url: URL) -> Outcome? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= headerSize else { return nil }

        guard (try? handle.seek(toOffset: 0)) != nil,
              let header = try? handle.read(upToCount: Int(headerSize)),
              header.count == Int(headerSize),
              header.subdata(in: 0..<4) == Data("RIFF".utf8),
              header.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }

        let byteRate = le32(header, 28)
        guard byteRate > 0 else { return nil }

        let declared = le32(header, 40)
        let actual = UInt32(clamping: fileSize - headerSize)
        let duration = Int(actual / byteRate)

        if declared == actual {
            return Outcome(durationSeconds: duration, repaired: false)
        }
        write32(handle, offset: 4, value: UInt32(clamping: fileSize - 8))   // RIFF chunk size
        write32(handle, offset: 40, value: actual)                          // data chunk size
        Log.recorder.info("WavRepair: починен \(url.lastPathComponent, privacy: .public) (\(actual) байт данных)")
        return Outcome(durationSeconds: duration, repaired: true)
    }

    private static func le32(_ d: Data, _ offset: Int) -> UInt32 {
        d.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    private static func write32(_ handle: FileHandle, offset: UInt64, value: UInt32) {
        var v = value.littleEndian
        try? handle.seek(toOffset: offset)
        try? handle.write(contentsOf: Data(bytes: &v, count: 4))
    }
}
