import Foundation

/// Статус встречи для отображения в UI. В отличие от `MeetingStatus`,
/// учитывает реальное наличие файлов на диске (старые записи без поля `status`).
enum EffectiveStatus: Equatable {
    case recording
    case processing
    case summarizing
    case ready
    case notTranscribed   // запись есть, ASR ещё не прогонялся
    case failed
    case discarded

    var label: String {
        switch self {
        case .recording:      return "Запись"
        case .processing:     return "Обработка"
        case .summarizing:    return "Анализирую"
        case .ready:          return "Готово"
        case .notTranscribed: return "Не расшифрована"
        case .failed:         return "Ошибка"
        case .discarded:      return "Отброшена"
        }
    }
}

/// Вью-модель одной встречи для ленты/календаря/деталей.
struct MeetingSummary: Identifiable, Equatable {
    let id: String
    let startedAt: Date
    let durationSeconds: Int
    let source: String
    let title: String
    let status: EffectiveStatus
    /// Сырой статус из meta.json (nil у старых записей и сирот). Нужен rescue/backfill;
    /// UI пользуется эффективным `status`.
    var metaStatus: MeetingStatus? = nil
    /// Есть ли на диске хотя бы одна аудио-дорожка.
    var hasAudio: Bool = false
    /// Аудио сжато в архив (`.m4a` вместо `.wav`, #83).
    var hasArchivedAudio: Bool = false
    let asrModel: String?
    let hasTranscript: Bool
    let hasInsights: Bool

    /// Длительность вида «48 с» / «32 мин» / «1 ч 05 мин».
    var durationText: String { MeetingSummary.formatDuration(durationSeconds) }

    // MARK: - Чистые билдеры (тестируются без файловой системы)

    static func make(folderId: String,
                     meta: MeetingMeta?,
                     hasAudio: Bool,
                     hasTranscript: Bool,
                     hasInsights: Bool = false,
                     hasArchivedAudio: Bool = false) -> MeetingSummary {
        let startedAt = meta?.startedAt ?? parseId(folderId) ?? Date(timeIntervalSince1970: 0)
        let status = effectiveStatus(metaStatus: meta?.status, hasAudio: hasAudio,
                                     hasTranscript: hasTranscript, hasInsights: hasInsights)
        return MeetingSummary(
            id: folderId,
            startedAt: startedAt,
            durationSeconds: meta?.durationSeconds ?? 0,
            source: meta?.source ?? "",
            title: meta?.title ?? fallbackTitle(for: startedAt),
            status: status,
            metaStatus: meta?.status,
            hasAudio: hasAudio,
            hasArchivedAudio: hasArchivedAudio,
            asrModel: meta?.asrModel,
            hasTranscript: hasTranscript,
            hasInsights: hasInsights)
    }

    static func effectiveStatus(metaStatus: MeetingStatus?,
                                hasAudio: Bool,
                                hasTranscript: Bool,
                                hasInsights: Bool = false) -> EffectiveStatus {
        if metaStatus == .summarizing { return .summarizing }
        if hasTranscript { return .ready }
        switch metaStatus {
        case .recording: return .recording
        case .processing, .summarizing: return .processing
        case .failed:     return .failed
        case .discarded:  return .discarded
        case .ready, .none: return .notTranscribed   // нет транскрипта → расшифровка не выполнена
        }
    }

    // MARK: - Форматирование

    static func formatDuration(_ s: Int) -> String {
        if s < 60 { return "\(s) с" }
        let m = s / 60
        let h = m / 60
        if h == 0 { return "\(m) мин" }
        return String(format: "%d ч %02d мин", h, m % 60)
    }

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func parseId(_ id: String) -> Date? { idFormatter.date(from: id) }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f
    }()

    static func fallbackTitle(for date: Date) -> String {
        "Встреча \(titleFormatter.string(from: date))"
    }
}
