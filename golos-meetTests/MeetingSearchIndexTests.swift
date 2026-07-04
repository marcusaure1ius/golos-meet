import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct MeetingSearchIndexTests {
    @Test func buildText_concatenatesTitleInsightsTranscript_lowercased() {
        let ins = MeetingInsights(meetingId: "m", llmModel: "x",
            generatedAt: Date(timeIntervalSince1970: 0), title: "Планёрка",
            summary: "Обсудили РЕЛИЗ", actionPoints: [ActionPoint(id: UUID(), text: "Выкатить", owner: nil)],
            schemaVersion: 1)
        let tr = Transcript(meetingId: "m", asrModel: "g",
            segments: [TranscriptSegment(start: 0, end: 1, speaker: .me, text: "Привет КОМАНДА")])
        let text = MeetingSearchIndex.buildText(title: "Планёрка", insights: ins, transcript: tr)
        #expect(text.contains("планёрка"))
        #expect(text.contains("релиз"))
        #expect(text.contains("выкатить"))
        #expect(text.contains("команда"))
        #expect(text == text.lowercased())
    }

    @Test func buildText_titleOnlyWhenNoArtifacts() {
        let text = MeetingSearchIndex.buildText(title: "Только имя", insights: nil, transcript: nil)
        #expect(text.contains("только имя"))
    }
}
