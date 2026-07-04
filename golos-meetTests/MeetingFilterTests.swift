import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct MeetingFilterTests {
    private func summary(_ id: String, _ started: Date) -> MeetingSummary {
        MeetingSummary(id: id, startedAt: started, durationSeconds: 600, source: "s",
                       title: id, status: .ready, asrModel: nil, hasTranscript: true, hasInsights: false)
    }

    @Test func filter_byQuery_caseInsensitive() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = summary("a", now), b = summary("b", now)
        let text: [String: String] = ["a": "обсудили релиз", "b": "про отпуск"]
        let out = MeetingFilter.apply([a, b], query: "РЕЛИЗ", period: .all, now: now) { text[$0] ?? "" }
        #expect(out.map(\.id) == ["a"])
    }

    @Test func filter_byPeriod_today() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let today = summary("t", now)
        let old = summary("o", now.addingTimeInterval(-3 * 24 * 3600))
        let out = MeetingFilter.apply([today, old], query: "", period: .today, now: now) { _ in "" }
        #expect(out.map(\.id) == ["t"])
    }

    @Test func filter_emptyQueryAllPeriod_returnsAll() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = summary("a", now), b = summary("b", now)
        let out = MeetingFilter.apply([a, b], query: "  ", period: .all, now: now) { _ in "" }
        #expect(out.count == 2)
    }

    @Test func filter_combinesQueryAndPeriod() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = summary("a", now)                                   // сегодня, матч
        let b = summary("b", now.addingTimeInterval(-10 * 24 * 3600)) // старая, матч по тексту
        let text = ["a": "релиз", "b": "релиз"]
        let out = MeetingFilter.apply([a, b], query: "релиз", period: .week, now: now) { text[$0] ?? "" }
        #expect(out.map(\.id) == ["a"])
    }
}
