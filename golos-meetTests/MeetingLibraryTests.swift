import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct MeetingLibraryTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func makeDir(_ root: URL, _ id: String) throws -> URL {
        let d = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func touch(_ url: URL, _ bytes: String = "x") throws { try bytes.data(using: .utf8)!.write(to: url) }

    @Test func scan_classifiesAndSorts() throws {
        let root = try tempRoot()
        // старая запись: только аудио, без meta
        let a = try makeDir(root, "2026-06-18_20-46-13"); try touch(a.appendingPathComponent("mic.wav"))
        // запись с meta(ready)+транскрипт
        let b = try makeDir(root, "2026-06-26_12-01-06")
        try touch(b.appendingPathComponent("system.wav"))
        let meta = MeetingMeta(id: "2026-06-26_12-01-06", source: "kontur.talk",
                               startedAt: Date(timeIntervalSince1970: 1_782_432_000),  // ≈ 2026-06-26 00:00 UTC
                               endedAt: Date(timeIntervalSince1970: 1_782_434_505),
                               durationSeconds: 2505, status: .ready, asrModel: "gigaam-v3",
                               title: nil, schemaVersion: 1)
        try MeetingMeta.encoded(meta).write(to: b.appendingPathComponent("meta.json"))
        try touch(b.appendingPathComponent("transcript.json"))

        let result = MeetingLibrary.scan(root: root)
        #expect(result.count == 2)
        #expect(result[0].id == "2026-06-26_12-01-06")          // новые сверху
        #expect(result[0].status == .ready)
        #expect(result[0].hasTranscript == true)
        #expect(result[1].status == .notTranscribed)            // старая аудио-only
    }

    @Test func transcript_decodesWhenPresent() throws {
        let root = try tempRoot()
        let d = try makeDir(root, "M")
        let t = Transcript(meetingId: "M", asrModel: "gigaam-v3",
                           segments: [TranscriptSegment(start: 0, end: 1, speaker: .me, text: "привет")])
        let enc = JSONEncoder()
        try enc.encode(t).write(to: d.appendingPathComponent("transcript.json"))

        let lib = MeetingLibrary(root: root)
        let decoded = lib.transcript(for: "M")
        #expect(decoded?.segments.first?.text == "привет")
        #expect(lib.transcript(for: "missing") == nil)
    }

    @Test func scan_excludesPhantomFolders() throws {
        let root = try tempRoot()
        // папка без аудио, без meta, без транскрипта — не должна попасть в результат
        _ = try makeDir(root, "phantom-empty-dir")
        // папка с аудио — должна попасть
        let a = try makeDir(root, "2026-06-18_20-46-13"); try touch(a.appendingPathComponent("mic.wav"))

        let result = MeetingLibrary.scan(root: root)
        #expect(result.count == 1)
        #expect(result[0].id == "2026-06-18_20-46-13")
    }

    @Test func scan_excludesDiscardedMeetings() throws {
        let root = try tempRoot()
        // discarded-«надгробие»: meta без аудио (пайплайн удалил WAV) — не в результат
        let d1 = try makeDir(root, "2026-06-20_10-00-00")
        let m1 = MeetingMeta(id: "2026-06-20_10-00-00", source: "kontur.talk",
                             startedAt: Date(timeIntervalSince1970: 1_781_900_000),
                             endedAt: Date(timeIntervalSince1970: 1_781_900_060),
                             durationSeconds: 60, status: .discarded, asrModel: nil,
                             title: nil, schemaVersion: 1)
        try MeetingMeta.encoded(m1).write(to: d1.appendingPathComponent("meta.json"))
        // discarded с уцелевшим аудио (краш между meta и удалением WAV) — тоже не в результат
        let d2 = try makeDir(root, "2026-06-21_10-00-00")
        let m2 = MeetingMeta(id: "2026-06-21_10-00-00", source: "kontur.talk",
                             startedAt: Date(timeIntervalSince1970: 1_781_990_000),
                             endedAt: Date(timeIntervalSince1970: 1_781_990_060),
                             durationSeconds: 60, status: .discarded, asrModel: nil,
                             title: nil, schemaVersion: 1)
        try MeetingMeta.encoded(m2).write(to: d2.appendingPathComponent("meta.json"))
        try touch(d2.appendingPathComponent("mic.wav"))
        // обычная встреча — в результат
        let ok = try makeDir(root, "2026-06-22_10-00-00"); try touch(ok.appendingPathComponent("mic.wav"))

        let result = MeetingLibrary.scan(root: root)
        #expect(result.count == 1)
        #expect(result[0].id == "2026-06-22_10-00-00")
    }

    @Test func reload_populatesPublished() throws {
        let root = try tempRoot()
        let a = try makeDir(root, "2026-06-18_20-46-13"); try touch(a.appendingPathComponent("mic.wav"))
        let lib = MeetingLibrary(root: root)
        #expect(lib.summaries.isEmpty)
        lib.reload()
        #expect(lib.summaries.count == 1)
    }

    @Test func insightsRoundTripAndHasInsightsFlag() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-lib-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("2026-06-30_10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // транскрипт (чтобы встреча попала в скан) + инсайты
        try Data("{}".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        let ins = MeetingInsights(meetingId: dir.lastPathComponent, llmModel: "m",
            generatedAt: Date(timeIntervalSince1970: 0), title: "Загол", summary: "С",
            actionPoints: [ActionPoint(id: UUID(), text: "A", owner: nil)], schemaVersion: 1)
        try ins.write(to: dir.appendingPathComponent("insights.json"))

        let summaries = MeetingLibrary.scan(root: root)
        #expect(summaries.first?.hasInsights == true)

        let lib = MeetingLibrary(root: root)
        #expect(lib.insights(for: dir.lastPathComponent)?.title == "Загол")
    }
}
