import Foundation

/// Группа встреч одного дня для ленты.
struct MeetingDayGroup: Identifiable, Equatable {
    let id: String        // ключ дня "yyyy-MM-dd"
    let label: String     // "Сегодня"/"Вчера"/"20 июня"
    let meetings: [MeetingSummary]
}

enum MeetingGrouping {
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM, EEEE"; return f
    }()

    /// Группирует встречи по календарному дню. Дни — новые сверху; внутри дня — новые сверху.
    static func group(_ meetings: [MeetingSummary], now: Date, calendar: Calendar = .current) -> [MeetingDayGroup] {
        let cal = calendar
        keyFormatter.timeZone = cal.timeZone
        dayFormatter.timeZone = cal.timeZone

        let sorted = meetings.sorted { $0.startedAt > $1.startedAt }
        var order: [Date] = []
        var buckets: [Date: [MeetingSummary]] = [:]
        for m in sorted {
            let day = cal.startOfDay(for: m.startedAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(m)
        }

        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        return order.map { day in
            let label: String
            if day == today { label = "Сегодня" }
            else if day == yesterday { label = "Вчера" }
            else { label = dayFormatter.string(from: day) }
            return MeetingDayGroup(id: keyFormatter.string(from: day), label: label, meetings: buckets[day]!)
        }
    }
}
