import Foundation
import os

@MainActor
final class AppCoordinator {
    private let detector = MeetingDetector()
    private let monitor = AudioProcessMonitor()
    private let recorder = Recorder()

    func start() {
        detector.delegate = recorder
        monitor.onActive = { [weak self] active in
            self?.detector.handle(active: active, at: Date())
        }
        monitor.start()
        Log.recorder.info("golos-meet запущен (accessory agent)")
    }
}
