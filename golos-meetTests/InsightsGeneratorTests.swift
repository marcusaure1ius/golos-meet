import Testing
import Foundation
@testable import golos_meet

@Suite struct InsightsGeneratorTests {
    static func sampleTranscript() -> Transcript {
        Transcript(meetingId: "M", asrModel: "gigaam-v3", segments: [
            TranscriptSegment(start: 0, end: 4, speaker: .participants, text: "Когда релиз?"),
            TranscriptSegment(start: 4, end: 9, speaker: .me, text: "Перенесём бету на июль."),
        ])
    }

    @Test func dialogRendersSpeakerLabelsWithoutTimecodes() {
        let text = InsightsPrompt.dialog(from: Self.sampleTranscript())
        #expect(text.contains("участники: Когда релиз?"))
        #expect(text.contains("я: Перенесём бету на июль."))
        #expect(!text.contains("0.0"))   // без таймкодов
    }
}
