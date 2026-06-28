import Testing
import Foundation
@testable import golos_meet

@Suite struct MeetingSummaryTests {
    @Test func effectiveStatus_transcriptWins() {
        #expect(MeetingSummary.effectiveStatus(metaStatus: .processing, hasAudio: true, hasTranscript: true) == .ready)
        #expect(MeetingSummary.effectiveStatus(metaStatus: nil, hasAudio: true, hasTranscript: true) == .ready)
    }

    @Test func effectiveStatus_fromMetaWhenNoTranscript() {
        #expect(MeetingSummary.effectiveStatus(metaStatus: .recording, hasAudio: true, hasTranscript: false) == .recording)
        #expect(MeetingSummary.effectiveStatus(metaStatus: .processing, hasAudio: true, hasTranscript: false) == .processing)
        #expect(MeetingSummary.effectiveStatus(metaStatus: .failed, hasAudio: true, hasTranscript: false) == .failed)
        #expect(MeetingSummary.effectiveStatus(metaStatus: .discarded, hasAudio: true, hasTranscript: false) == .discarded)
    }

    @Test func effectiveStatus_oldRecordingNoMeta() {
        #expect(MeetingSummary.effectiveStatus(metaStatus: nil, hasAudio: true, hasTranscript: false) == .notTranscribed)
    }

    @Test func make_noMeta_parsesIdAndFallbackTitle() {
        let s = MeetingSummary.make(folderId: "2026-06-18_20-46-13", meta: nil, hasAudio: true, hasTranscript: false)
        #expect(s.id == "2026-06-18_20-46-13")
        #expect(s.status == .notTranscribed)
        #expect(s.title == "Встреча 20:46")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        #expect(cal.component(.hour, from: s.startedAt) == 20)
        #expect(cal.component(.minute, from: s.startedAt) == 46)
    }

    @Test func make_metaTitlePreferred() {
        let meta = MeetingMeta(id: "M", source: "kontur.talk",
                               startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                               endedAt: Date(timeIntervalSince1970: 1_700_001_920),
                               durationSeconds: 1920, status: .ready, asrModel: "gigaam-v3",
                               title: "Планёрка", schemaVersion: 1)
        let s = MeetingSummary.make(folderId: "M", meta: meta, hasAudio: true, hasTranscript: true)
        #expect(s.title == "Планёрка")
        #expect(s.asrModel == "gigaam-v3")
        #expect(s.status == .ready)
    }

    @Test func durationText_formats() {
        #expect(MeetingSummary(id: "x", startedAt: .now, durationSeconds: 48, source: "", title: "t", status: .ready, asrModel: nil, hasTranscript: false).durationText == "48 с")
        #expect(MeetingSummary(id: "x", startedAt: .now, durationSeconds: 1920, source: "", title: "t", status: .ready, asrModel: nil, hasTranscript: false).durationText == "32 мин")
        #expect(MeetingSummary(id: "x", startedAt: .now, durationSeconds: 3905, source: "", title: "t", status: .ready, asrModel: nil, hasTranscript: false).durationText == "1 ч 05 мин")
    }
}
