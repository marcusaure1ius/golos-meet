import Testing
import Foundation
@testable import golos_meet

/// Архивация старых записей (#83): отбор кандидатов, конвертация, восстановление.
@MainActor
@Suite struct ArchiveCandidateTests {
    private func writeWav(_ url: URL, seconds: Double) async throws {
        let w = try WavWriter(url: url)
        await w.append(Data(count: Int(16_000 * seconds) * 2))
        try await w.finalize()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-cand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeMeeting(in root: URL, id: String, daysAgo: Double,
                             status: MeetingStatus = .ready, withWav: Bool = true,
                             withTranscript: Bool = true, now: Date = Date()) async throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ended = now.addingTimeInterval(-daysAgo * 86_400)
        let meta = MeetingMeta(id: id, source: "kontur.talk", startedAt: ended.addingTimeInterval(-120),
                               endedAt: ended, durationSeconds: 120, status: status, asrModel: "gigaam-v3")
        try MeetingMeta.encoded(meta).write(to: dir.appendingPathComponent("meta.json"))
        if withWav {
            let w = try WavWriter(url: dir.appendingPathComponent("mic.wav"))
            await w.append(Data(count: 16_000 * 2))
            try await w.finalize()
        }
        if withTranscript { try Data("{}".utf8).write(to: dir.appendingPathComponent("transcript.json")) }
        return dir
    }

    @Test func oldReadyMeetingIsCandidate() async throws {
        let root = try makeRoot()
        _ = try await makeMeeting(in: root, id: "2026-01-01_10-00-00", daysAgo: 120)
        let candidates = MeetingArchiver.candidates(in: root, olderThanDays: 90)
        #expect(candidates.count == 1)
    }

    @Test func freshMeetingIsNotCandidate() async throws {
        let root = try makeRoot()
        _ = try await makeMeeting(in: root, id: "2026-01-01_10-00-00", daysAgo: 10)
        #expect(MeetingArchiver.candidates(in: root, olderThanDays: 90).isEmpty)
    }

    @Test func activeStatusesAreNotCandidates() async throws {
        let root = try makeRoot()
        _ = try await makeMeeting(in: root, id: "2026-01-01_10-00-00", daysAgo: 120, status: .processing)
        _ = try await makeMeeting(in: root, id: "2026-01-02_10-00-00", daysAgo: 120, status: .recording)
        #expect(MeetingArchiver.candidates(in: root, olderThanDays: 90).isEmpty)
    }

    @Test func withoutTranscriptIsNotCandidate() async throws {
        let root = try makeRoot()
        _ = try await makeMeeting(in: root, id: "2026-01-01_10-00-00", daysAgo: 120, withTranscript: false)
        #expect(MeetingArchiver.candidates(in: root, olderThanDays: 90).isEmpty)
    }

    @Test func zeroThresholdDisablesArchive() async throws {
        let root = try makeRoot()
        _ = try await makeMeeting(in: root, id: "2026-01-01_10-00-00", daysAgo: 120)
        #expect(MeetingArchiver.candidates(in: root, olderThanDays: 0).isEmpty)
    }
}

@MainActor
@Suite struct ArchiveConversionTests {
    private func writeWav(_ url: URL, seconds: Double) async throws {
        let w = try WavWriter(url: url)
        await w.append(Data(count: Int(16_000 * seconds) * 2))
        try await w.finalize()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-conv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeOldMeeting(in root: URL, id: String) async throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ended = Date().addingTimeInterval(-120 * 86_400)
        let meta = MeetingMeta(id: id, source: "kontur.talk", startedAt: ended.addingTimeInterval(-120),
                               endedAt: ended, durationSeconds: 120, status: .ready, asrModel: "gigaam-v3")
        try MeetingMeta.encoded(meta).write(to: dir.appendingPathComponent("meta.json"))
        try Data("{\"segments\":[]}".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        return dir
    }

    @Test func archiveReplacesWavWithM4aAndFlagsMeta() async throws {
        let root = try makeRoot()
        let dir = try await makeOldMeeting(in: root, id: "2026-01-01_10-00-00")
        try await writeWav(dir.appendingPathComponent("mic.wav"), seconds: 1.0)

        try MeetingArchiver.archiveMeeting(at: dir)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("mic.m4a").path))
        let meta = try MeetingMeta.decoded(try Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.archivedAudio == true)
        // Расшифровка и метаданные остались несжатыми.
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path))
    }

    @Test func archivedAudioPlaysWithSeekableDuration() async throws {
        let root = try makeRoot()
        let dir = try await makeOldMeeting(in: root, id: "2026-01-01_10-00-00")
        try await writeWav(dir.appendingPathComponent("system.wav"), seconds: 1.0)
        try MeetingArchiver.archiveMeeting(at: dir)

        let player = MeetingPlayer(folder: dir)
        #expect(player.hasAudio)
        #expect(abs(player.duration - 1.0) < 0.3)
    }

    @Test func failedConversionKeepsWavIntact() async throws {
        let root = try makeRoot()
        let dir = try await makeOldMeeting(in: root, id: "2026-01-01_10-00-00")
        // Невалидный «WAV» (не RIFF) — конвертация обязана упасть, не трогая файл.
        try Data(count: 64).write(to: dir.appendingPathComponent("mic.wav"))

        #expect(throws: (any Error).self) {
            try MeetingArchiver.archiveMeeting(at: dir)
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.m4a").path))
    }

    @Test func repairMetaFlagCoversCrashBetweenWavRemovalAndMetaWrite() async throws {
        let root = try makeRoot()
        let dir = try await makeOldMeeting(in: root, id: "2026-01-01_10-00-00")
        // Состояние после краша: m4a на диске, wav удалён, флаг не успели записать.
        try Data(count: 128).write(to: dir.appendingPathComponent("mic.m4a"))

        MeetingArchiver.repairMetaFlag(at: dir)

        let meta = try MeetingMeta.decoded(try Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.archivedAudio == true)
    }

    @Test func repairDoesNotTouchFreshWavMeeting() async throws {
        let root = try makeRoot()
        let dir = try await makeOldMeeting(in: root, id: "2026-01-01_10-00-00")
        try Data(count: 128).write(to: dir.appendingPathComponent("mic.wav"))

        MeetingArchiver.repairMetaFlag(at: dir)

        let meta = try MeetingMeta.decoded(try Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.archivedAudio == nil)
    }
}

@MainActor
@Suite struct ArchiveReaderTests {
    @Test func libraryDetectsM4aOnlyAsAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026-01-01_10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ended = Date().addingTimeInterval(-120 * 86_400)
        let meta = MeetingMeta(id: "2026-01-01_10-00-00", source: "kontur.talk",
                               startedAt: ended.addingTimeInterval(-120), endedAt: ended,
                               durationSeconds: 120, status: .ready, asrModel: "gigaam-v3")
        var archived = meta
        archived.archivedAudio = true
        try MeetingMeta.encoded(archived).write(to: dir.appendingPathComponent("meta.json"))
        try Data("{\"segments\":[]}".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        try Data(count: 128).write(to: dir.appendingPathComponent("mic.m4a"))

        let summaries = MeetingLibrary.scan(root: root)
        #expect(summaries.count == 1)
        #expect(summaries.first?.status == .ready)
        #expect(summaries.first?.hasAudio == true)
        #expect(summaries.first?.hasArchivedAudio == true)
    }
}

@MainActor
@Suite struct ArchiveRunnerTests {
    @Test func runOnceArchivesOldAndSkipsFresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeMeeting(_ id: String, daysAgo: Double) async throws -> URL {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ended = Date().addingTimeInterval(-daysAgo * 86_400)
            let meta = MeetingMeta(id: id, source: "kontur.talk", startedAt: ended.addingTimeInterval(-120),
                                   endedAt: ended, durationSeconds: 120, status: .ready, asrModel: "gigaam-v3")
            try MeetingMeta.encoded(meta).write(to: dir.appendingPathComponent("meta.json"))
            try Data("{\"segments\":[]}".utf8).write(to: dir.appendingPathComponent("transcript.json"))
            let w = try WavWriter(url: dir.appendingPathComponent("mic.wav"))
            await w.append(Data(count: 16_000 * 2))
            try await w.finalize()
            return dir
        }
        _ = try await makeMeeting("2026-01-01_10-00-00", daysAgo: 120)
        _ = try await makeMeeting("2026-06-01_10-00-00", daysAgo: 10)

        let runner = ArchiveRunner(root: root, thresholdDays: { 90 })
        let archived = await runner.runOnce()

        #expect(archived == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-01-01_10-00-00/mic.wav").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-06-01_10-00-00/mic.wav").path))
        // Повторный проход ничего не меняет (уже архивировано).
        #expect(await runner.runOnce() == 0)
    }
}
