import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct BackfillTests {
    @Test func run_enqueuesOnlyMeetingsWithAudioAndNoTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-backfill-\(UUID().uuidString)", isDirectory: true)

        func makeMeeting(_ id: String, audio: Bool, transcript: Bool) throws {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta = MeetingMeta(id: id, source: "kontur.talk",
                                   startedAt: Date(timeIntervalSince1970: 0),
                                   endedAt: Date(timeIntervalSince1970: 600),
                                   durationSeconds: 600, status: .ready, asrModel: nil)
            try meta.write(to: dir.appendingPathComponent("meta.json"))
            if audio { try Data(count: 100).write(to: dir.appendingPathComponent("mic.wav")) }
            if transcript { try Data("{}".utf8).write(to: dir.appendingPathComponent("transcript.json")) }
        }
        try makeMeeting("2026-07-01_09-00-00", audio: true, transcript: false)   // → в очередь
        try makeMeeting("2026-07-01_10-00-00", audio: true, transcript: true)    // уже расшифрована
        try makeMeeting("2026-07-01_11-00-00", audio: false, transcript: false)  // нечего обрабатывать

        var processed: [String] = []
        let proc = MeetingProcessor(
            processWork: { url, config in
                processed.append(url.lastPathComponent)
                #expect(config.deleteShortAudio == false)   // backfill короткие не удаляет
            },
            insightsWork: { _, _ in })

        Backfill.run(processor: proc, root: root)
        await proc.enqueueAndWait(.process(deleteShortAudio: false),
                                  id: "2026-07-01_09-00-00",
                                  folder: root.appendingPathComponent("2026-07-01_09-00-00", isDirectory: true))
        #expect(processed == ["2026-07-01_09-00-00"])
    }
}
