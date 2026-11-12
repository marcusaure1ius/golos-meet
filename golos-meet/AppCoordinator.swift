import Foundation
import AppKit
import Combine
import os

@MainActor
final class AppCoordinator: MeetingDetectorDelegate {
    struct Dependencies {
        let recorder: Recorder
        let state: RecordingState
        let observer: TalkRoomObserver
        let selection: () -> TalkRuntimeSelection
        let now: () -> Date
        var startLegacy: (@escaping (Bool?, Bool?) -> Void) -> Void = { _ in }
        var stopLegacy: () -> Void = {}
        var automaticObserver: TalkAutomaticObserver? = nil
        var automaticStatus: TalkAutomaticStatus? = nil
    }
    private enum Owner { case api, legacy, manual }
    let detector: MeetingDetector
    let recorder: Recorder
    private let state: RecordingState
    private let observer: TalkRoomObserver
    private let automaticObserver: TalkAutomaticObserver
    private let automaticStatus: TalkAutomaticStatus
    private let loadSelection: () -> TalkRuntimeSelection
    private let now: () -> Date
    private let startLegacy: (@escaping (Bool?, Bool?) -> Void) -> Void
    private let stopLegacy: () -> Void
    private let synthetic: Bool
    private var selection: TalkRuntimeSelection = .unavailable
    private var running = false
    private var hasLoadedSelection = false
    private var sleeping = false
    private var quitting = false
    private var owner: Owner?
    private var suppressed = false
    private var lastAudioActive = false
    private var lastWindowActive = false
    private var boundary: Task<Void, Never>?
    private var menuBar: MenuBarController?
    private var stateCancellable: AnyCancellable?
    private var timer: Timer?
    private var settingsListener: UUID?
    private var sleepTokens: [NSObjectProtocol] = []
    private(set) var detectionLine = "Автозапись: ожидание настройки"

    /// Injecting dependencies explicitly opts into synthetic coordinator execution;
    /// the default constructor/start path is blocked before real stores/monitors.
    init(dependencies: Dependencies? = nil, graceSeconds: TimeInterval = 30) {
        synthetic = dependencies != nil
        detector = MeetingDetector(graceSeconds: graceSeconds)
        if let dependencies {
            automaticObserver = dependencies.automaticObserver ?? TalkAutomaticObserver()
            automaticStatus = dependencies.automaticStatus ?? TalkAutomaticStatus()
            recorder = dependencies.recorder; state = dependencies.state; observer = dependencies.observer
            loadSelection = dependencies.selection; now = dependencies.now
            startLegacy = dependencies.startLegacy; stopLegacy = dependencies.stopLegacy
        } else {
            automaticObserver = TalkAutomaticObserver(); automaticStatus = .shared
            recorder = Recorder(); state = .shared; observer = TalkRoomObserver()
            loadSelection = { TalkRuntimeSettings.production() }; now = { Date() }
            let audio = AudioProcessMonitor(), window = WindowMonitor()
            startLegacy = { callback in
                audio.onActive = { callback($0, nil) }; window.onActive = { callback(nil, $0) }
                audio.start(); window.start()
            }
            stopLegacy = { audio.stop(); window.stop() }
        }
    }

    func start() {
        guard !running, !quitting, !AppRuntime.isTestHost || synthetic else { return }
        running = true; quitting = false
        detector.delegate = self
        recorder.onCaptureFailure = { [weak self] in
            guard let self else { return }
            self.owner = nil; self.suppressed = true; self.detector.captureFailed(); self.renderMenu()
        }
        reloadConfiguration()
        if !synthetic {
            installMenuBar()
            settingsListener = TalkSettingsChanges.observe { [weak self] in self?.reloadConfiguration() }
            let center = NSWorkspace.shared.notificationCenter
            sleepTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            })
            sleepTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            })
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pulse() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
            stateCancellable = state.objectWillChange.sink { [weak self] in
                Task { @MainActor [weak self] in self?.renderMenu() }
            }
        }
        pulse()
    }

    func reloadConfiguration() {
        guard running, !quitting else { return }
        let next = loadSelection()
        guard !hasLoadedSelection || next != selection else { return }
        hasLoadedSelection = true
        stopLegacy(); observer.stop(); automaticObserver.stop(); automaticStatus.observation = .stopped; detector.reset()
        lastAudioActive = false; lastWindowActive = false
        // A manual recording belongs to the user, not to a changing API config.
        if owner != .manual { interruptSegment() }
        selection = next
        applySelection()
    }

    private func applySelection() {
        guard running, !quitting, !sleeping else { return }
        switch selection {
        case .automatic(let config, let enabled):
            if let config {
                automaticObserver.configure(config); automaticObserver.resume(); automaticObserver.start()
                automaticStatus.observation = automaticObserver.observation
                detectionLine = automaticObserver.observation.text
            } else {
                automaticStatus.observation = .stopped
                detectionLine = enabled ? "Определение встреч: подтвердите аккаунт в настройках" : "Определение встреч выключено"
            }
        case .legacy:
            detectionLine = "Автодетект: эвристика аудио и окон Толка"
            startLegacy { [weak self] audio, window in self?.update(audio: audio, window: window) }
        case .api(let config):
            if let config { observer.configure(config); observer.resume(); observer.start(); detectionLine = observer.observation.presence.statusText }
            else { detectionLine = "API Толка: сохраните PAT, комнаты и подтвердите аккаунт" }
        case .unavailable: detectionLine = "Автозапись недоступна: не удалось прочитать настройки"
        }
        renderMenu()
    }

    /// One production timer reads the freshness-checked getter, even while idle.
    /// Tests drive this same entry point with an injected monotonic clock.
    func pulse() {
        guard running, !quitting, !sleeping else { return }
        if case .automatic(.some, _) = selection {
            // Diagnostic mode never forwards positive/negative states to Recorder.
            automaticStatus.observation = automaticObserver.observation
            detectionLine = automaticObserver.observation.text
        }
        if case .api(.some) = selection {
            let presence = observer.observation.presence
            detectionLine = presence.statusText
            switch presence {
            case .present:
                if suppressed { detectionLine += " · автостарт приостановлен до следующей встречи" }
                if !suppressed, owner == nil, !recorder.isRecording, boundary == nil {
                    owner = .api
                    if !recorder.meetingStarted(at: now(), manual: false) { owner = nil; suppressed = true }
                }
            case .absent:
                suppressed = false
                if owner == .api { owner = nil; recorder.meetingEnded(at: now()) }
            case .unknown: break // Never call legacy false/MeetingDetector on unknown.
            }
        }
        renderMenu()
    }

    /// Stale legacy callbacks cannot influence API/manual sessions.
    func update(audio: Bool? = nil, window: Bool? = nil) {
        guard running, !quitting, !sleeping, selection == .legacy, boundary == nil, owner != .manual else { return }
        if let audio { lastAudioActive = audio }
        if let window { lastWindowActive = window }
        let active = lastAudioActive || lastWindowActive
        if suppressed { if !active { suppressed = false }; return }
        detector.handle(active: active, at: now())
    }

    func meetingStarted(at date: Date, manual: Bool) -> Bool {
        guard running, !quitting, !sleeping, boundary == nil, owner == nil else { return false }
        let accepted = recorder.meetingStarted(at: date, manual: manual)
        if accepted { owner = manual ? .manual : .legacy }
        return accepted
    }
    func meetingEnded(at date: Date) { owner = nil; recorder.meetingEnded(at: date) }

    func toggleRecording() {
        guard running, !quitting, !sleeping, state.phase != .stopping, boundary == nil else { return }
        if recorder.isRecording {
            suppressed = true; owner = nil; detector.reset()
            // Preserve manually stopped short audio and retain normal processing.
            recorder.end(at: now(), preserveAudio: true)
        } else {
            detector.reset()
            _ = meetingStarted(at: now(), manual: true)
        }
        renderMenu()
    }

    private func interruptSegment() {
        owner = nil
        guard recorder.isRecording, boundary == nil else { return }
        let recorder = recorder, date = now()
        boundary = Task { [weak self] in
            _ = await recorder.finalizeActive(endedAt: date, preserveAudio: true)
            self?.boundary = nil
        }
    }

    func willSleep() {
        guard running, !quitting else { return }
        sleeping = true; observer.pause(); automaticObserver.pause(); stopLegacy(); detector.reset()
        automaticStatus.observation = automaticObserver.observation
        detectionLine = "Автозапись: пауза на время сна"
        interruptSegment(); renderMenu()
    }
    func didWake() {
        guard running, !quitting, sleeping else { return }
        sleeping = false
        // Force a fresh configure, even if saved configuration is identical.
        selection = loadSelection()
        applySelection(); pulse()
    }

    /// Called before AppDelegate's existing 3-second termination race.
    /// Pollers/settings callbacks are disabled synchronously, no new capture can win.
    func prepareForTermination() {
        guard running else { return }
        quitting = true; running = false
        observer.stop(); automaticObserver.stop(); automaticStatus.observation = .stopped; stopLegacy(); detector.reset()
        timer?.invalidate(); timer = nil
        if let settingsListener { TalkSettingsChanges.remove(settingsListener) }; settingsListener = nil
        sleepTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; sleepTokens = []
        stateCancellable = nil; menuBar?.uninstall(); menuBar = nil
    }

    var menuModel: MenuBarModel {
        .from(live: state.live, now: now(), phase: state.phase,
              microphone: state.microphone, system: state.system, detectionLine: detectionLine)
    }
    private func installMenuBar() {
        let menu = MenuBarController(onToggleRecording: { [weak self] in self?.toggleRecording() },
                                     onOpenWindow: { Self.openMainWindow() }, onQuit: { NSApp.terminate(nil) })
        menu.install(); menuBar = menu; renderMenu()
    }
    private func renderMenu() { menuBar?.render(menuModel) }
    static func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain { window.makeKeyAndOrderFront(nil); return }
    }
}
