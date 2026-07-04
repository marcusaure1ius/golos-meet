import AppKit

/// Чистая модель состояния меню-бара — решает, что показать; рендер в `MenuBarController`.
struct MenuBarModel: Equatable {
    let isRecording: Bool
    let startStopTitle: String
    let statusLine: String
    let iconRecording: Bool

    static func from(live: RecordingState.Live?, now: Date) -> MenuBarModel {
        guard let live else {
            return MenuBarModel(isRecording: false,
                                startStopTitle: "Начать запись",
                                statusLine: "Автодетект активен",
                                iconRecording: false)
        }
        let elapsed = elapsedText(Int(now.timeIntervalSince(live.startedAt)))
        let prefix = live.isManual ? "Запись" : "Запись (авто)"
        return MenuBarModel(isRecording: true,
                            startStopTitle: "Остановить запись",
                            statusLine: "\(prefix) · \(elapsed)",
                            iconRecording: true)
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
