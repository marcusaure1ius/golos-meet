import Foundation

/// Период фильтрации ленты.
enum MeetingPeriod: String, CaseIterable, Identifiable {
    case all, today, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:   return "Все"
        case .today: return "Сегодня"
        case .week:  return "7 дней"
        case .month: return "30 дней"
        }
    }
    /// Порог «не раньше» относительно now; nil для .all.
    func cutoff(now: Date) -> Date? {
        switch self {
        case .all:   return nil
        case .today: return Calendar.current.startOfDay(for: now)
        case .week:  return now.addingTimeInterval(-7 * 24 * 3600)
        case .month: return now.addingTimeInterval(-30 * 24 * 3600)
        }
    }
}

/// Чистая фильтрация ленты по тексту и периоду (И). Текст встречи берётся через
/// замыкание `textFor` — в проде это `MeetingSearchIndex.text(for:)`, в тестах — стаб.
enum MeetingFilter {
    static func apply(_ summaries: [MeetingSummary], query: String, period: MeetingPeriod,
                      now: Date, textFor: (String) -> String) -> [MeetingSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cutoff = period.cutoff(now: now)
        return summaries.filter { s in
            if let cutoff, s.startedAt < cutoff { return false }
            if !q.isEmpty, !textFor(s.id).contains(q) { return false }
            return true
        }
    }
}
