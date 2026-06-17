import Foundation
import os

@MainActor
final class AppCoordinator {
    func start() {
        Log.recorder.info("golos-meet запущен (accessory agent)")
    }
}
