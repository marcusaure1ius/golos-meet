import Testing
import Foundation
@testable import golos_meet

/// Решение «догнать недоделанные» — чистая функция `MeetingProcessor.catchUpJobs`.
@MainActor
@Suite struct MeetingCatchUpTests {

    private func summary(_ id: String,
                         audio: Bool = true,
                         transcript: Bool = false,
                         insights: Bool = false,
                         status: MeetingStatus? = nil) -> MeetingSummary {
        let meta = status.map {
            MeetingMeta(id: id, source: "test",
                        startedAt: Date(timeIntervalSince1970: 0),
                        endedAt: Date(timeIntervalSince1970: 60),
                        durationSeconds: 60, status: $0, asrModel: nil)
        }
        return MeetingSummary.make(folderId: id, meta: meta,
                                   hasAudio: audio, hasTranscript: transcript, hasInsights: insights)
    }

    @Test func noTranscript_withAudio_needsFullProcess() {
        let jobs = MeetingProcessor.catchUpJobs(for: [summary("a")], insightsEnabled: true)
        #expect(jobs == [CatchUpJob(id: "a", kind: .process(deleteShortAudio: true))])
    }

    @Test func transcriptWithoutInsights_needsInsights() {
        let jobs = MeetingProcessor.catchUpJobs(for: [summary("b", transcript: true)], insightsEnabled: true)
        #expect(jobs == [CatchUpJob(id: "b", kind: .insights)])
    }

    @Test func fullyDone_needsNothing() {
        let jobs = MeetingProcessor.catchUpJobs(
            for: [summary("c", transcript: true, insights: true)], insightsEnabled: true)
        #expect(jobs.isEmpty)
    }

    @Test func insightsDisabled_skipsInsightsCatchUp() {
        let jobs = MeetingProcessor.catchUpJobs(for: [summary("b", transcript: true)], insightsEnabled: false)
        #expect(jobs.isEmpty)
    }

    @Test func failedWithAudio_reprocesses() {
        let jobs = MeetingProcessor.catchUpJobs(for: [summary("f", status: .failed)], insightsEnabled: true)
        #expect(jobs == [CatchUpJob(id: "f", kind: .process(deleteShortAudio: true))])
    }

    @Test func recording_isSkipped() {
        let jobs = MeetingProcessor.catchUpJobs(
            for: [summary("live", transcript: false, status: .recording)], insightsEnabled: true)
        #expect(jobs.isEmpty)
    }

    @Test func orphanWithoutAudioOrTranscript_needsNothing() {
        let jobs = MeetingProcessor.catchUpJobs(
            for: [summary("orphan", audio: false)], insightsEnabled: true)
        #expect(jobs.isEmpty)
    }

    @Test func mixedLibrary_picksOnlyUnfinished() {
        let lib = [
            summary("done", transcript: true, insights: true),
            summary("needsAsr"),
            summary("needsInsights", transcript: true),
            summary("live", status: .recording),
        ]
        let jobs = MeetingProcessor.catchUpJobs(for: lib, insightsEnabled: true)
        #expect(jobs == [
            CatchUpJob(id: "needsAsr", kind: .process(deleteShortAudio: true)),
            CatchUpJob(id: "needsInsights", kind: .insights),
        ])
    }
}
