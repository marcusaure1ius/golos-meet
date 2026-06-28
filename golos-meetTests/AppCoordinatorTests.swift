import Testing
import Foundation
@testable import golos_meet

// MARK: - Spy

private final class SpyDetectorDelegate: MeetingDetectorDelegate {
    var startedCount = 0
    var endedCount = 0
    func meetingStarted(at _: Date) { startedCount += 1 }
    func meetingEnded(at _: Date) { endedCount += 1 }
}

// MARK: - Tests

/// Проверяет OR-логику AppCoordinator: встреча активна, если активен ХОТЯ БЫ ОДИН сигнал
/// (аудио ИЛИ окно). Регрессия здесь сломала бы всё обнаружение встреч.
@MainActor
@Suite struct AppCoordinatorTests {

    /// Только аудио-сигнал истинен → детектор получает active=true → meetingStarted
    @Test func audioSignalAloneActivatesMeeting() {
        let coordinator = AppCoordinator()
        let spy = SpyDetectorDelegate()
        coordinator.detector.delegate = spy
        coordinator.update(audio: true)
        #expect(spy.startedCount == 1)
    }

    /// Только оконный сигнал истинен → детектор получает active=true → meetingStarted
    @Test func windowSignalAloneActivatesMeeting() {
        let coordinator = AppCoordinator()
        let spy = SpyDetectorDelegate()
        coordinator.detector.delegate = spy
        coordinator.update(window: true)
        #expect(spy.startedCount == 1)
    }

    /// Оба сигнала ложны → детектор получает active=false → встреча не начинается
    @Test func bothSignalsFalseDoesNotStartMeeting() {
        let coordinator = AppCoordinator()
        let spy = SpyDetectorDelegate()
        coordinator.detector.delegate = spy
        coordinator.update(audio: false)
        coordinator.update(window: false)
        #expect(spy.startedCount == 0)
    }
}
