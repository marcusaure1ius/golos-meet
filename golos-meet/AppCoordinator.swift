import Foundation
import AppKit
import Combine
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
    let recorder = Recorder()

    // Последние значения каждого сигнала; встреча активна, если активен ХОТЯ БЫ ОДИН
    // (аудио ловит захват микрофона Толком; окно ловит присутствие в звонке независимо от тишины/фокуса).
    private var lastAudioActive = false
    private var lastWindowActive = false

    private var menuBar: MenuBarController?
    private var liveCancellable: AnyCancellable?
    private var tickTimer: Timer?

    func start() {
        detector.delegate = recorder
        recorder.onCaptureFailure = { [weak self] in self?.detector.captureFailed() }
        audioMonitor.onActive = { [weak self] active in self?.update(audio: active) }
        windowMonitor.onActive = { [weak self] active in self?.update(window: active) }
        audioMonitor.start()
        windowMonitor.start()
        installMenuBar()
        Log.recorder.info("golos-meet запущен")
    }

    func update(audio: Bool? = nil, window: Bool? = nil) {
        if let audio { lastAudioActive = audio }
        if let window { lastWindowActive = window }
        detector.handle(active: lastAudioActive || lastWindowActive, at: Date())
    }

    // MARK: - Menu bar

    private func installMenuBar() {
        let mb = MenuBarController(
            onToggleRecording: { [weak self] in self?.toggleRecording() },
            onOpenWindow: { AppCoordinator.openMainWindow() },
            onQuit: { NSApp.terminate(nil) })
        mb.install()
        menuBar = mb
        liveCancellable = RecordingState.shared.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.onLiveChanged(RecordingState.shared.live) }
        }
        renderMenu()
    }

    private func toggleRecording() {
        guard RecordingState.shared.phase != .stopping else { return }
        if !recorder.isRecording {
            detector.forceStart(at: Date())
        } else {
            detector.forceStop(at: Date())
        }
    }

    private func onLiveChanged(_ live: RecordingState.Live?) {
        renderMenu()
        if live == nil { stopTick() } else { startTick() }
    }

    private func renderMenu() {
        let state = RecordingState.shared
        menuBar?.render(.from(live: state.live, now: Date(), phase: state.phase,
                             microphone: state.microphone, system: state.system))
    }

    private func startTick() {
        guard tickTimer == nil else { return }
        // .common — чтобы «Запись · MM:SS» тикала и при открытом меню (event-tracking mode).
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderMenu() }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func stopTick() { tickTimer?.invalidate(); tickTimer = nil }

    /// Поднять/сфокусировать окно приложения из меню-бара.
    static func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.canBecomeMain {
            w.makeKeyAndOrderFront(nil)
            return
        }
    }
}
