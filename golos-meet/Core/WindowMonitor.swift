import CoreGraphics
import Foundation
import os

/// Опрашивает список видимых окон и проверяет, есть ли на экране окно звонка Толка.
///
/// В звонке Толк показывает либо полноценное окно встречи (`title="Встреча"`, когда Толк
/// впереди), либо плавающий PiP-оверлей (`title="ktalk"`, layer 1000), который остаётся
/// `onscreen=true` поверх других приложений, когда Толк уведён на фон. После выхода из звонка
/// видимых окон звонка нет. Сигнал **не зависит от тишины и активного приложения** — это его
/// преимущество над аудио-активностью (которая гаснет в тишине). См.
/// `docs/plans/2026-06-18-window-aware-detection.md`.
///
/// Строго `.optionOnScreenOnly`: через `.optionAll` объекты окон висят скрытыми и после выхода.
/// Заголовки окон требуют разрешения Screen Recording (уже выдано для записи); без него
/// title=nil → сигнал тихо false → откат на аудио-only.
final class WindowMonitor {
    var onActive: ((Bool) -> Void)?
    private let pollInterval: TimeInterval
    private let titles: Set<String>
    private var timer: Timer?

    /// Заголовки окон, означающих активный звонок. «ktalk» locale-independent; «Встреча» — RU-клиент.
    static let callWindowTitles: Set<String> = ["Встреча", "ktalk"]

    init(pollInterval: TimeInterval = 1.5, titles: Set<String> = WindowMonitor.callWindowTitles) {
        self.pollInterval = pollInterval
        self.titles = titles
    }

    /// Чистый матч: окно принадлежит Толку И его заголовок в списке окон звонка.
    static func isCallWindow(owner: String?, title: String?,
                             titles: Set<String> = callWindowTitles) -> Bool {
        guard let owner, let title else { return false }
        let lo = owner.lowercased()
        guard lo.contains("толк") || lo.contains("talk") || lo.contains("kontur") else { return false }
        return titles.contains(title)
    }

    func start() {
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer = t
        poll()
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: - Private

    private func poll() {
        let active = hasOnscreenCallWindow()
        Log.detector.debug("WindowMonitor poll: active=\(active)")
        onActive?(active)
    }

    private func hasOnscreenCallWindow() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String
            let title = w[kCGWindowName as String] as? String
            if Self.isCallWindow(owner: owner, title: title, titles: titles) { return true }
        }
        return false
    }
}
