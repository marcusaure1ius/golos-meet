import Foundation
import Testing
@testable import golos_meet

@Suite struct PCMWriteSinkTests {
    @Test func closeDrainsAllAcceptedBuffersAndRejectsLateWrites() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sink-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url)
        let sink = PCMWriteSink(writer: writer, onFailure: { Issue.record("Unexpected write failure") })
        for i in 0..<100 { sink.append(Data([UInt8(i), 0])) }
        await sink.close()
        sink.append(Data([255, 0]))
        try await writer.finalize()
        try await writer.finalize()
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 244)
        #expect(Array(bytes.dropFirst(44)) == (0..<100).flatMap { [UInt8($0), 0] })
        #expect(await writer.append(Data([1, 0])) == false)
    }

    @Test func writeFailureIsReportedOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sink-error-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url)
        try await writer.finalize()
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let sink = PCMWriteSink(writer: writer) { continuation.yield(()) }
        sink.append(Data([0, 0]))
        sink.append(Data([0, 0]))
        await sink.close()
        continuation.finish()
        var count = 0
        for await _ in events { count += 1 }
        #expect(count == 1)
    }
}
