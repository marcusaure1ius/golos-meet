import Foundation

nonisolated enum TalkAudioCaptureError: LocalizedError, Equatable, Sendable {
    case nativeClientNotFound, invalidProcesses, sourceUnavailable, processDisappeared, noDisplay

    var errorDescription: String? {
        switch self {
        case .nativeClientNotFound: "Нативный Толк не найден. Откройте приложение и повторите запись."
        case .invalidProcesses: "Не удалось однозначно определить процессы Толка."
        case .sourceUnavailable: "Не удалось проверить источник Толка. Проверьте разрешение записи экрана."
        case .processDisappeared: "Выбранный процесс Толка исчез. Повторите запуск записи."
        case .noDisplay: "Нет доступного дисплея для захвата звука Толка."
        }
    }
}
