import AppKit

/// Чистая модель состояния меню-бара — решает, что показать; рендер в `MenuBarController`.
struct MenuBarModel: Equatable {
    let isRecording: Bool
    let startStopTitle: String
    let statusLine: String
    let iconRecording: Bool
    var buttonTitle: String = ""
    var tracksLine: String = ""
    var canToggle: Bool = true
    var detectionLine: String = ""

    static func from(live: RecordingState.Live?, now: Date,
                     phase: RecordingState.Phase? = nil,
                     microphone: RecordingState.TrackStatus = .ready,
                     system: RecordingState.TrackStatus = .ready,
                     detectionLine: String = "") -> MenuBarModel {
        var model = captureModel(live: live, now: now, phase: phase, microphone: microphone, system: system)
        model.detectionLine = detectionLine
        if live == nil, phase == nil || phase == .idle, !detectionLine.isEmpty { model = MenuBarModel(isRecording: false, startStopTitle: "Начать запись", statusLine: detectionLine, iconRecording: false) }
        model.detectionLine = detectionLine
        return model
    }

    private static func captureModel(live: RecordingState.Live?, now: Date, phase: RecordingState.Phase?,
                                     microphone: RecordingState.TrackStatus, system: RecordingState.TrackStatus) -> MenuBarModel {
        let phase = phase ?? (live == nil ? .idle : .recording)
        let tracksLine = "Микрофон: \(trackText(microphone)) · Системный звук: \(trackText(system))"
        switch phase {
        case .starting:
            return MenuBarModel(isRecording: false, startStopTitle: "Отменить запуск",
                                statusLine: "Подготовка дорожек…", iconRecording: false,
                                buttonTitle: "…", tracksLine: tracksLine)
        case .stopping:
            return MenuBarModel(isRecording: false, startStopTitle: "Сохраняем запись…",
                                statusLine: "Завершение и сохранение записи…", iconRecording: false,
                                buttonTitle: "…", tracksLine: tracksLine, canToggle: false)
        case .failed(let message):
            return MenuBarModel(isRecording: false, startStopTitle: "Повторить запись",
                                statusLine: message, iconRecording: false,
                                buttonTitle: "!", tracksLine: tracksLine)
        default: break
        }
        guard let live else {
            return MenuBarModel(isRecording: false,
                                startStopTitle: "Начать запись",
                                statusLine: "Автодетект: эвристика аудио и окон Толка",
                                iconRecording: false)
        }
        let elapsed = elapsedText(Int(now.timeIntervalSince(live.startedAt)))
        let prefix = live.isManual ? "Запись" : "Запись (авто)"
        return MenuBarModel(isRecording: true,
                            startStopTitle: "Остановить запись",
                            statusLine: "\(prefix) · \(elapsed)",
                            iconRecording: true, buttonTitle: elapsed, tracksLine: tracksLine)
    }

    private static func trackText(_ status: RecordingState.TrackStatus) -> String {
        switch status {
        case .waiting: "ожидание"
        case .ready: "готов"
        case .stopped: "остановлен"
        case .failed: "ошибка"
        }
    }
}

/// NSObject-мост для `NSMenuItem.target` — @MainActor-класс не может быть target напрямую
/// в Swift 6 strict concurrency.
final class MenuBarTarget: NSObject {
    private let toggleAction: () -> Void
    private let openAction: () -> Void
    private let quitAction: () -> Void
    init(toggle: @escaping () -> Void, open: @escaping () -> Void, quit: @escaping () -> Void) {
        self.toggleAction = toggle; self.openAction = open; self.quitAction = quit
    }
    @objc func toggle(_ sender: Any?) { toggleAction() }
    @objc func open(_ sender: Any?) { openAction() }
    @objc func quit(_ sender: Any?) { quitAction() }
}
