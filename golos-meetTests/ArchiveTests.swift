import Testing
import Foundation
import AVFoundation
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

    @Test func archiveReplacesWavWithCafAndFlagsMeta() async throws {
        let root = try makeRoot()
        let dir = try await makeOldMeeting(in: root, id: "2026-01-01_10-00-00")
        try await writeWav(dir.appendingPathComponent("mic.wav"), seconds: 1.0)

        try MeetingArchiver.archiveMeeting(at: dir)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
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
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
    }

    @Test func repairMetaFlagCoversCrashBetweenWavRemovalAndMetaWrite() async throws {
        let root = try makeRoot()
        let dir = try await makeOldMeeting(in: root, id: "2026-01-01_10-00-00")
        // Состояние после краша: caf на диске, wav удалён, флаг не успели записать.
        try Data(count: 128).write(to: dir.appendingPathComponent("mic.caf"))

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

    @Test func crashBetweenRenameAndWavRemovalRecoversOnNextAttempt() async throws {
        let root = try makeRoot()
        let dir = try await makeOldMeeting(in: root, id: "2026-01-01_10-00-00")
        try await writeWav(dir.appendingPathComponent("mic.wav"), seconds: 1.0)
        // Артефакт краша: caf уже переименован, но wav ещё не удалён (мусорный контент).
        try Data(count: 128).write(to: dir.appendingPathComponent("mic.caf"))

        // Следующий проход обязан сойтись, а не падать вечно на занятом имени.
        try MeetingArchiver.archiveMeeting(at: dir)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        let player = MeetingPlayer(folder: dir)
        #expect(player.hasAudio)
        #expect(abs(player.duration - 1.0) < 0.3)
        let meta = try MeetingMeta.decoded(try Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.archivedAudio == true)
    }

    @Test func flagStaysFalseWhenOneTrackRemainsUncompressed() async throws {
        let root = try makeRoot()
        let dir = try await makeOldMeeting(in: root, id: "2026-01-01_10-00-00")
        // mic уже сжат (wav удалён), system.wav перманентно бит → конвертация падает.
        try Data(count: 128).write(to: dir.appendingPathComponent("mic.caf"))
        try Data(count: 128).write(to: dir.appendingPathComponent("system.wav"))

        #expect(throws: (any Error).self) {
            try MeetingArchiver.archiveMeeting(at: dir)
        }
        let meta = try MeetingMeta.decoded(try Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.archivedAudio == nil)
        // repairMetaFlag тоже не должен лгать о частичной архивации.
        MeetingArchiver.repairMetaFlag(at: dir)
        let repaired = try MeetingMeta.decoded(try Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(repaired.archivedAudio == nil)
    }
}

@MainActor
@Suite struct ArchiveReaderTests {
    @Test func libraryDetectsCafOnlyAsAudio() async throws {
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
        try Data(count: 128).write(to: dir.appendingPathComponent("mic.caf"))

        let summaries = MeetingLibrary.scan(root: root)
        #expect(summaries.count == 1)
        #expect(summaries.first?.status == .ready)
        #expect(summaries.first?.hasAudio == true)
        #expect(summaries.first?.hasArchivedAudio == true)
    }
}

/// Lossless-гарантия FLAC (#129): roundtrip PCM байт-в-байт и восстановление
/// WAV для переобработки ASR (sidecar читает только WAV).
@MainActor
@Suite struct ArchiveFlacLosslessTests {
    enum ArchiveTestError: Error { case chunkNotFound }

    /// PCM-данные из data-чанка WAV (минимальный RIFF-парс).
    private func wavPcm(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var i = 12
        while i + 8 <= data.count {
            let id = String(bytes: data[i..<i + 4], encoding: .ascii) ?? ""
            let size = Int(data[i + 4]) | Int(data[i + 5]) << 8 | Int(data[i + 6]) << 16 | Int(data[i + 7]) << 24
            if id == "data" { return data.subdata(in: (i + 8)..<min(i + 8 + size, data.count)) }
            i += 8 + size + (size % 2)
        }
        throw ArchiveTestError.chunkNotFound
    }

    /// Декодирует файл через AVAudioFile (тот же путь, что у плеера и restore).
    private func decodeSamples(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let floats = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        return floats.map { f in
            let v = (f * 32_768.0).rounded()
            return Int16(max(-32_768, min(32_767, v)))
        }
    }

    /// Детерминированный «речеподобный» узор — FLAC обязан сохранить любой бит.
    private func writePatternWav(_ url: URL, seconds: Double) async throws -> Data {
        let count = Int(16_000 * seconds)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count { samples[i] = Int16((i * 257) % 32_000 - 16_000) }
        var pcm = Data(count: count * 2)
        pcm.withUnsafeMutableBytes { raw in
            _ = samples.withUnsafeBytes { src in
                raw.copyBytes(from: src)
            }
        }
        let w = try WavWriter(url: url)
        await w.append(pcm)
        try await w.finalize()
        return pcm
    }

    private func makeOldMeetingDir(root: URL, id: String) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ended = Date().addingTimeInterval(-120 * 86_400)
        let meta = MeetingMeta(id: id, source: "kontur.talk", startedAt: ended.addingTimeInterval(-120),
                               endedAt: ended, durationSeconds: 120, status: .ready, asrModel: "gigaam-v3")
        try MeetingMeta.encoded(meta).write(to: dir.appendingPathComponent("meta.json"))
        try Data("{\"segments\":[]}".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        return dir
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-flac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func flacRoundtripPreservesExactPcm() async throws {
        let root = try makeRoot()
        let dir = try makeOldMeetingDir(root: root, id: "2026-01-01_10-00-00")
        let original = try await writePatternWav(dir.appendingPathComponent("mic.wav"), seconds: 1.5)

        try MeetingArchiver.archiveMeeting(at: dir)

        let decoded = try decodeSamples(dir.appendingPathComponent("mic.caf"))
        var decodedData = Data(count: decoded.count * 2)
        decodedData.withUnsafeMutableBytes { raw in
            _ = decoded.withUnsafeBytes { src in
                raw.copyBytes(from: src)
            }
        }
        #expect(decodedData == original)
    }

    @Test func restoreWavBringsBackByteIdenticalAudio() async throws {
        let root = try makeRoot()
        let dir = try makeOldMeetingDir(root: root, id: "2026-01-01_10-00-00")
        let original = try await writePatternWav(dir.appendingPathComponent("mic.wav"), seconds: 1.5)
        try MeetingArchiver.archiveMeeting(at: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))

        let restored = try MeetingArchiver.restoreWav(at: dir)

        #expect(restored.count == 1)
        #expect(try wavPcm(dir.appendingPathComponent("mic.wav")) == original)
        // .caf остаётся на месте — чтению и плееру ничего не сломалось.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        // Флаг сброшен: при живом WAV UI не должен показывать «сжато» (ревью P2-3).
        let meta = try MeetingMeta.decoded(try Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.archivedAudio == false)
    }

    @Test func restoreSkipsMixedStateWithLiveWav() async throws {
        let root = try makeRoot()
        let dir = try await makeOldMeetingDir(root: root, id: "2026-01-01_10-00-00")
        // Смешанное состояние после сбоя: caf и «живой» wav рядом — WAV авторитетен.
        try Data(count: 128).write(to: dir.appendingPathComponent("mic.caf"))
        let liveWav = Data(repeating: 0x42, count: 256)
        try liveWav.write(to: dir.appendingPathComponent("mic.wav"))

        let restored = try MeetingArchiver.restoreWav(at: dir)

        #expect(restored.isEmpty)
        // Сырое сравнение: liveWav — не валидный WAV, chunk-парсер здесь неприменим.
        #expect(try Data(contentsOf: dir.appendingPathComponent("mic.wav")) == liveWav)
        // Флаг не тронут: полной архивации не было и восстановления не было.
        let meta = try MeetingMeta.decoded(try Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.archivedAudio == nil)
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

        // isEnabled инжектирован: без него дефолт читает UserDefaults.standard —
        // реальный дом пользователя (в этой базе нет preferences-изоляции).
        let runner = ArchiveRunner(root: root, thresholdDays: { 90 }, isEnabled: { true })
        let archived = await runner.runOnce()

        #expect(archived == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-01-01_10-00-00/mic.wav").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-06-01_10-00-00/mic.wav").path))
        // Повторный проход ничего не меняет (уже архивировано).
        #expect(await runner.runOnce() == 0)
    }

    @Test func disabledRunnerSkipsArchivingUntilForced() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026-01-01_10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ended = Date().addingTimeInterval(-120 * 86_400)
        let meta = MeetingMeta(id: "2026-01-01_10-00-00", source: "kontur.talk",
                               startedAt: ended.addingTimeInterval(-120), endedAt: ended,
                               durationSeconds: 120, status: .ready, asrModel: "gigaam-v3")
        try MeetingMeta.encoded(meta).write(to: dir.appendingPathComponent("meta.json"))
        try Data("{\"segments\":[]}".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        let w = try WavWriter(url: dir.appendingPathComponent("mic.wav"))
        await w.append(Data(count: 16_000 * 2))
        try await w.finalize()

        // Выключенная авто-архивация: обычный проход ничего не делает.
        let runner = ArchiveRunner(root: root, thresholdDays: { 90 }, isEnabled: { false })
        #expect(await runner.runOnce() == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))

        // Ручной запуск из настроек работает независимо от выключателя.
        #expect(await runner.runOnce(force: true) == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
    }

    @Test func runnerSkipsMeetingBusyInProcessingQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026-01-01_10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ended = Date().addingTimeInterval(-120 * 86_400)
        let meta = MeetingMeta(id: "2026-01-01_10-00-00", source: "kontur.talk",
                               startedAt: ended.addingTimeInterval(-120), endedAt: ended,
                               durationSeconds: 120, status: .ready, asrModel: "gigaam-v3")
        try MeetingMeta.encoded(meta).write(to: dir.appendingPathComponent("meta.json"))
        try Data("{\"segments\":[]}".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        let w = try WavWriter(url: dir.appendingPathComponent("mic.wav"))
        await w.append(Data(count: 16_000 * 2))
        try await w.finalize()

        // Встреча в очереди переобработки — архиватор не трогает её WAV (ревью P1-1).
        let runner = ArchiveRunner(root: root, thresholdDays: { 90 },
                                   busyIds: { ["2026-01-01_10-00-00"] })
        #expect(await runner.runOnce() == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
    }
}
