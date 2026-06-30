import Testing
import Foundation
@testable import golos_meet

@Suite struct MeetingGroupingTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Moscow")!; return c }

    private func summary(_ id: String, _ date: Date) -> MeetingSummary {
        MeetingSummary(id: id, startedAt: date, durationSeconds: 0, source: "", title: id, status: .ready, asrModel: nil, hasTranscript: false, hasInsights: false)
    }

    @Test func groupsByDayWithRelativeLabels() {
        let c = cal
        let now = c.date(from: DateComponents(year: 2026, month: 6, day: 28, hour: 15))!
        let todayA = c.date(from: DateComponents(year: 2026, month: 6, day: 28, hour: 9))!
        let todayB = c.date(from: DateComponents(year: 2026, month: 6, day: 28, hour: 14))!
        let yest = c.date(from: DateComponents(year: 2026, month: 6, day: 27, hour: 16))!
        let old = c.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 11))!

        let groups = MeetingGrouping.group([summary("a", todayA), summary("o", old), summary("b", todayB), summary("y", yest)], now: now, calendar: c)

        #expect(groups.count == 3)
        #expect(groups[0].label == "Сегодня")
        #expect(groups[0].meetings.map(\.id) == ["b", "a"])   // внутри дня — новые сверху
        #expect(groups[1].label == "Вчера")
        #expect(groups[2].meetings.map(\.id) == ["o"])
        #expect(groups[2].label.contains("20"))               // дата вида «20 июня, суббота»
        #expect(groups[2].label.contains("суббота"))           // 2026-06-20 — суббота (день недели)
    }

    @Test func emptyInputYieldsNoGroups() {
        #expect(MeetingGrouping.group([], now: .now).isEmpty)
    }
}
