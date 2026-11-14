import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct StartupRescueTests {
    /// Временный корень meetings/ с одной встречей в заданном статусе.
    private func makeMeeting(in root: URL, id: String, status: MeetingStatus,
                             brokenWavDataBytes: Int? = nil) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = MeetingMeta(id: id, source: "kontur.talk",
                               startedAt: Date(timeIntervalSince1970: 1_000_000),
                               endedAt: Date(timeIntervalSince1970: 1_000_000),
                               durationSeconds: 0, status: status, asrModel: nil,
                               title: "t", schemaVersion: 1)
        try meta.write(to: dir.appendingPathComponent("meta.json"))
        if let bytes = brokenWavDataBytes {
            // Заголовок с data size = 0 (как у оборванной записи) + данные.
            var d = Data()
            func le32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
            func le16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
            d.append(Data("RIFF".utf8)); le32(36); d.append(Data("WAVE".utf8))
            d.append(Data("fmt ".utf8)); le32(16); le16(1); le16(1)
            le32(16_000); le32(32_000); le16(2); le16(16)
            d.append(Data("data".utf8)); le32(0)
            d.append(Data(count: bytes))
            try d.write(to: dir.appendingPathComponent("mic.wav"))
        }
        return dir
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-rescue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func recording_wavRepaired_metaClosed_folderReturned() throws {
        let root = try makeRoot()
        // 320 000 байт = 10 c при 16 кГц mono Int16.
        let dir = try makeMeeting(in: root, id: "2026-07-01_10-00-00", status: .recording,
                                  brokenWavDataBytes: 320_000)
        let rescued = StartupRescue.run(root: root)
        #expect(rescued == [dir])
        let meta = try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.durationSeconds == 10)
        #expect(meta.endedAt == meta.startedAt.addingTimeInterval(10))
        #expect(meta.status == .recording)
        #expect(meta.preserveAudio == true)
        // Заголовок починен.
        let wav = try Data(contentsOf: dir.appendingPathComponent("mic.wav"))
        let dataField = wav.subdata(in: 40..<44).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        #expect(dataField == 320_000)
    }

    @Test func processing_folderReturned_metaUntouched() throws {
        let root = try makeRoot()
        let dir = try makeMeeting(in: root, id: "2026-07-01_11-00-00", status: .processing)
        let rescued = StartupRescue.run(root: root)
        #expect(rescued == [dir])
        let meta = try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.status == .processing)
    }

    @Test func shortInterruptedCaptureSurvivesRescueAndDefaultPipeline() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeMeeting(in: root, id: "short-interrupted", status: .recording,
                                  brokenWavDataBytes: 320_000)
        #expect(StartupRescue.run(root: root) == [dir])
        let repaired = try Data(contentsOf: dir.appendingPathComponent("mic.wav"))
        let pipeline = ProcessingPipeline(asrFactory: { ProcessingPipelineTests.StubASR() })
        await pipeline.process(folder: dir)
        let meta = try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.status == .ready)
        #expect(meta.preserveAudio == true)
        #expect(try Data(contentsOf: dir.appendingPathComponent("mic.wav")) == repaired)
    }

    @Test func failedProtectionWriteDoesNotEnqueueLegacyShortAudio() async throws {
        let root = try makeRoot()
        let dir = try makeMeeting(in: root, id: "legacy-short", status: .recording)
        let metaURL = dir.appendingPathComponent("meta.json")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metaURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        for name in ["mic.wav", "system.wav"] {
            let writer = try WavWriter(url: dir.appendingPathComponent(name))
            await writer.append(Data(repeating: 0, count: 32_000))
            try await writer.finalize()
        }
        let micBefore = try Data(contentsOf: dir.appendingPathComponent("mic.wav"))
        let systemBefore = try Data(contentsOf: dir.appendingPathComponent("system.wav"))
        let metadataBefore = try Data(contentsOf: metaURL)
        var protected = try MeetingMeta.decoded(metadataBefore)
        #expect(protected.preserveAudio == nil)
        protected.preserveAudio = true
        // Real APFS failure of Foundation's atomic replacement, no injected throw.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: metaURL.path)
        #expect(throws: (any Error).self) { try protected.write(to: metaURL) }
        let rescued = StartupRescue.run(root: root)
        #expect(rescued.isEmpty)
        var asrCreated = false
        let pipeline = ProcessingPipeline(asrFactory: {
            asrCreated = true
            return ProcessingPipelineTests.StubASR()
        })
        for folder in rescued { await pipeline.process(folder: folder) }
        #expect(!asrCreated)
        #expect(try Data(contentsOf: metaURL) == metadataBefore)
        #expect(try Data(contentsOf: dir.appendingPathComponent("mic.wav")) == micBefore)
        #expect(try Data(contentsOf: dir.appendingPathComponent("system.wav")) == systemBefore)
        // Once saving is possible, the same folder can safely be rescued and processed.
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metaURL.path)
        #expect(StartupRescue.run(root: root) == [dir])
        await pipeline.process(folder: dir)
        #expect(asrCreated)
        #expect(try Data(contentsOf: dir.appendingPathComponent("mic.wav")) == micBefore)
    }

    @Test func summarizing_becomesReady_notReturned() throws {
        let root = try makeRoot()
        let dir = try makeMeeting(in: root, id: "2026-07-01_12-00-00", status: .summarizing)
        let rescued = StartupRescue.run(root: root)
        #expect(rescued.isEmpty)
        let meta = try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.status == .ready)
    }

    @Test func terminalStatuses_untouched_notReturned() throws {
        let root = try makeRoot()
        for (i, status) in [MeetingStatus.ready, .failed, .discarded].enumerated() {
            _ = try makeMeeting(in: root, id: "2026-07-01_13-0\(i)-00", status: status)
        }
        #expect(StartupRescue.run(root: root).isEmpty)
    }
}
