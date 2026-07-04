import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct MeetingPlayerTests {
    /// Пишет короткий валидный WAV указанной длительности (сек) в файл.
    private func writeWav(_ url: URL, seconds: Double) async throws {
        let w = try WavWriter(url: url)                 // 16кГц mono Int16
        let samples = Int(16_000 * seconds)
        await w.append(Data(count: samples * 2))        // тишина (append не throwing)
        try await w.finalize()
    }
    private func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("player-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func duration_isMaxOfTracks() async throws {
        let dir = try folder()
        try await writeWav(dir.appendingPathComponent("mic.wav"), seconds: 1.0)
        try await writeWav(dir.appendingPathComponent("system.wav"), seconds: 2.0)
        let player = MeetingPlayer(folder: dir)
        #expect(player.hasAudio)
        #expect(abs(player.duration - 2.0) < 0.2)
    }

    @Test func missingOneTrack_stillPlays() async throws {
        let dir = try folder()
        try await writeWav(dir.appendingPathComponent("system.wav"), seconds: 1.0)
        let player = MeetingPlayer(folder: dir)
        #expect(player.hasAudio)
        #expect(abs(player.duration - 1.0) < 0.2)
    }

    @Test func noAudio_hasAudioFalse() throws {
        let dir = try folder()
        let player = MeetingPlayer(folder: dir)
        #expect(!player.hasAudio)
        #expect(player.duration == 0)
    }

    @Test func seek_clampsAndSetsCurrentTime() async throws {
        let dir = try folder()
        try await writeWav(dir.appendingPathComponent("mic.wav"), seconds: 2.0)
        let player = MeetingPlayer(folder: dir)
        player.seek(to: 5.0)                            // за пределы → клампится к duration
        #expect(player.currentTime <= player.duration + 0.01)
        player.seek(to: -1.0)
        #expect(player.currentTime >= 0)
    }
}
