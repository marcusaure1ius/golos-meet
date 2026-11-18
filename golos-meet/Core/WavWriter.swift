import Foundation
import os

/// Пишет поток Int16 LE PCM в .wav. Header дописывается размерами в finalize().
actor WavWriter {
    private let handle: FileHandle
    private let url: URL
    private let sampleRate: Int
    private let channels: Int
    private var dataBytes: UInt32 = 0
    private var closed = false
    private var appendFailed = false
    enum Failure: Error { case appendFailed }

    init(url: URL, sampleRate: Int = 16_000, channels: Int = 1) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataBytes: 0, sampleRate: sampleRate, channels: channels))
    }

    @discardableResult
    func append(_ pcm: Data) -> Bool {
        guard !closed else { return false }
        guard !pcm.isEmpty else { return true }
        do {
            try handle.write(contentsOf: pcm)
            dataBytes &+= UInt32(pcm.count)
            return true
        } catch {
            appendFailed = true
            Log.recorder.error("WavWriter append failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func finalize() throws {
        guard !closed else { return }
        defer { closed = true; try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytes, sampleRate: sampleRate, channels: channels))
        try handle.synchronize()
        if appendFailed { throw Failure.appendFailed }
    }

    /// Канонический 44-байтный WAV/PCM16 header.
    private static func header(dataBytes: UInt32, sampleRate: Int, channels: Int) -> Data {
        let byteRate = UInt32(sampleRate * channels * 2)
        let blockAlign = UInt16(channels * 2)
        var d = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); le32(36 &+ dataBytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); le32(16); le16(1); le16(UInt16(channels))
        le32(UInt32(sampleRate)); le32(byteRate); le16(blockAlign); le16(16)
        d.append(Data("data".utf8)); le32(dataBytes)
        return d
    }
}
