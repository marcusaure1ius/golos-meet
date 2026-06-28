import SwiftUI

/// Месяц-сетка: на днях со встречами — точка. Клик по дню → список встреч этого дня ниже.
struct MeetingCalendarView: View {
    @Environment(\.palette) var p
    let meetings: [MeetingSummary]
    let onSelect: (MeetingSummary) -> Void

    @State private var monthAnchor: Date = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay: Date?

    private var cal: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c } // пн

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "LLLL yyyy"; return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                monthHeader
                weekdayRow
                grid
                if let day = selectedDay {
                    dayList(day)
                }
            }
            .padding(.horizontal, 56).padding(.vertical, 16)
        }
    }

    // Дни встреч в текущем отображаемом месяце → ключ startOfDay.
    private var meetingDays: Set<Date> {
        Set(meetings.map { cal.startOfDay(for: $0.startedAt) })
    }

    private var monthHeader: some View {
        HStack(spacing: 12) {
            Text(Self.monthFmt.string(from: monthAnchor).capitalized)
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(p.ink)
            Spacer()
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundStyle(p.muted)
            Button { monthAnchor = cal.startOfDay(for: Date()); selectedDay = nil } label: { Text("Сегодня").font(.system(size: 13)) }.buttonStyle(GhostButton())
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).foregroundStyle(p.muted)
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(["Пн","Вт","Ср","Чт","Пт","Сб","Вс"], id: \.self) { d in
                Text(d).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted2)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        let days = monthGridDays()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                dayCell(day)
            }
        }
    }

    @ViewBuilder private func dayCell(_ day: Date?) -> some View {
        if let day {
            let inMonth = cal.isDate(day, equalTo: monthAnchor, toGranularity: .month)
            let hasMeetings = meetingDays.contains(cal.startOfDay(for: day))
            let isSelected = selectedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 13))
                    .foregroundStyle(inMonth ? p.ink : p.muted2)
                Circle().fill(hasMeetings ? p.accent : Color.clear).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(isSelected ? p.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { if hasMeetings { selectedDay = cal.startOfDay(for: day) } }
        } else {
            Color.clear.frame(height: 40)
        }
    }

    @ViewBuilder private func dayList(_ day: Date) -> some View {
        let items = meetings.filter { cal.isDate($0.startedAt, inSameDayAs: day) }
            .sorted { $0.startedAt > $1.startedAt }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { m in
                MeetingCard(meeting: m).contentShape(Rectangle()).onTapGesture { onSelect(m) }
            }
        }
        .padding(.top, 8)
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) { monthAnchor = d; selectedDay = nil }
    }

    /// Ячейки сетки месяца: ведущие/замыкающие nil-паддинги до полных недель.
    private func monthGridDays() -> [Date?] {
        guard let monthInterval = cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let firstOfMonth = monthInterval.start
        let daysInMonth = cal.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        // Смещение от firstWeekday (пн=2) до первого дня месяца.
        let weekdayOfFirst = cal.component(.weekday, from: firstOfMonth)
        let lead = (weekdayOfFirst - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for i in 0..<daysInMonth {
            cells.append(cal.date(byAdding: .day, value: i, to: firstOfMonth))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
}
