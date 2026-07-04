import Foundation
import AppKit
import Combine
import os

@MainActor
final class AppCoordinator {
    // grace-окно спада можно укоротить через env (для e2e); по умолчанию 30 c.
    private static var graceSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["GM_GRACE_SECONDS"],
           let v = TimeInterval(raw) { return v }
        return 30
    }

    let detector = MeetingDetector(graceSeconds: AppCoordinator.graceSeconds)
    private let audioMonitor = AudioProcessMonitor()
    private let windowMonitor = WindowMonitor()
    let recorder = Recorder()

    private var lastAudioActive = false
    private var lastWindowActive = false

    private var menuBar: MenuBarController?
    private var liveCancellable: AnyCancellable?
    private var tickTimer: Timer?

    func start() {
        detector.delegate = recorder
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
        liveCancellable = RecordingState.shared.$live.sink { [weak self] live in
            Task { @MainActor in self?.onLiveChanged(live) }
        }
        renderMenu()
    }

    private func toggleRecording() {
        if RecordingState.shared.live == nil {
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
        menuBar?.render(.from(live: RecordingState.shared.live, now: Date()))
    }

    private func startTick() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderMenu() }
        }
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
