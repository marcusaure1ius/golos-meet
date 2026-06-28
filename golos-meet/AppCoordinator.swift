import Foundation
import os

@MainActor
final class AppCoordinator {
    // grace-окно спада можно укоротить через env (для e2e); по умолчанию 30 c.
    // Оконный сигнал держит активность сквозь тишину, поэтому длинный grace больше не нужен
    // (см. docs/plans/2026-06-18-window-aware-detection.md).
    private static var graceSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["GM_GRACE_SECONDS"],
           let v = TimeInterval(raw) { return v }
        return 30
    }

    let detector = MeetingDetector(graceSeconds: AppCoordinator.graceSeconds)
    private let audioMonitor = AudioProcessMonitor()
    private let windowMonitor = WindowMonitor()
    private let recorder = Recorder()

    // Последние значения каждого сигнала; встреча активна, если активен ХОТЯ БЫ ОДИН
    // (аудио ловит звук; окно ловит присутствие в звонке независимо от тишины/фокуса).
    private var lastAudioActive = false
    private var lastWindowActive = false

    func start() {
        detector.delegate = recorder
        audioMonitor.onActive = { [weak self] active in self?.update(audio: active) }
        windowMonitor.onActive = { [weak self] active in self?.update(window: active) }
        audioMonitor.start()
        windowMonitor.start()
        Log.recorder.info("golos-meet запущен (accessory agent)")
    }

    func update(audio: Bool? = nil, window: Bool? = nil) {
        if let audio { lastAudioActive = audio }
        if let window { lastWindowActive = window }
        detector.handle(active: lastAudioActive || lastWindowActive, at: Date())
    }
}
