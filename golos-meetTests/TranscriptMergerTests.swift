import Testing
import Foundation
@testable import golos_meet

@Suite struct TranscriptMergerTests {
    private func seg(_ s: Double, _ e: Double, _ t: String) -> TimedSegment {
        TimedSegment(start: s, end: e, text: t)
    }

    @Test func mergeSortsByStartAndLabels() {
        let t = TranscriptMerger.merge(
            meetingId: "M", asrModel: "gigaam-v3",
            me: [seg(4.5, 9.1, "да")],
            participants: [seg(0.0, 4.2, "привет")])
        #expect(t.segments.map(\.text) == ["привет", "да"])
        #expect(t.segments.map(\.speaker) == [.participants, .me])
    }

    @Test func mergeFromSingleTrack() {
        let t = TranscriptMerger.merge(meetingId: "M", asrModel: "g",
                                       me: [seg(0, 1, "соло")], participants: [])
        #expect(t.segments.count == 1)
        #expect(t.segments[0].speaker == .me)
    }

    @Test func emptyInputsGiveEmptyTranscript() {
        let t = TranscriptMerger.merge(meetingId: "M", asrModel: "g", me: [], participants: [])
        #expect(t.segments.isEmpty)
    }

    @Test func timecodeFormatsMinutesAndHours() {
        #expect(TranscriptMerger.timecode(0) == "00:00")
        #expect(TranscriptMerger.timecode(75) == "01:15")
        #expect(TranscriptMerger.timecode(3661) == "1:01:01")
    }

    @Test func markdownHasLocalizedSpeakersAndTimecodes() {
        let t = TranscriptMerger.merge(meetingId: "M", asrModel: "g",
                                       me: [seg(4, 9, "да")],
                                       participants: [seg(0, 4, "привет")])
        let md = TranscriptMerger.renderMarkdown(t, title: "Встреча")
        #expect(md.contains("**[00:00] участники:** привет"))
        #expect(md.contains("**[00:04] я:** да"))
    }

    @Test func jsonRoundTrips() throws {
        let t = TranscriptMerger.merge(meetingId: "M", asrModel: "g",
                                       me: [seg(0, 1, "x")], participants: [])
        let data = try TranscriptMerger.renderJSON(t)
        let back = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(back == t)
    }
}
