import Testing
import Foundation
@testable import golos_meet

@Suite struct MenuBarModelTests {
    private let t0 = Date(timeIntervalSince1970: 0)

    @Test func idleWhenNoLive() {
        let m = MenuBarModel.from(live: nil, now: t0)
        #expect(m.isRecording == false)
        #expect(m.startStopTitle == "Начать запись")
        #expect(m.statusLine == "Автодетект: эвристика аудио и окон Толка")
        #expect(m.iconRecording == false)
    }

    @Test func manualRecordingShowsElapsed() {
        let live = RecordingState.Live(id: "m1", startedAt: t0, isManual: true)
        let m = MenuBarModel.from(live: live, now: t0.addingTimeInterval(204)) // 3:24
        #expect(m.isRecording == true)
        #expect(m.startStopTitle == "Остановить запись")
        #expect(m.statusLine == "Запись · 03:24")
        #expect(m.iconRecording == true)
    }

    @Test func autoRecordingIsLabelled() {
        let live = RecordingState.Live(id: "m1", startedAt: t0, isManual: false)
        let m = MenuBarModel.from(live: live, now: t0.addingTimeInterval(5))
        #expect(m.statusLine == "Запись (авто) · 00:05")
    }

    @Test func startingShowsReadinessAndAllowsCancellation() {
        let model = MenuBarModel.from(live: nil, now: t0, phase: .starting,
                                      microphone: .ready, system: .waiting)
        #expect(!model.isRecording && !model.iconRecording)
        #expect(model.startStopTitle == "Отменить запуск")
        #expect(model.tracksLine == "Микрофон: готов · Системный звук: ожидание")
        #expect(model.canToggle)
    }

    @Test func stoppingCannotStartAnotherCapture() {
        let live = RecordingState.Live(id: "m", startedAt: t0, isManual: true)
        let model = MenuBarModel.from(live: live, now: t0, phase: .stopping)
        #expect(!model.canToggle)
        #expect(!model.iconRecording)
        #expect(model.statusLine.contains("сохранение"))
    }

    @Test func failureCannotBeDisplayedAsSuccessfulRecording() {
        let model = MenuBarModel.from(live: nil, now: t0, phase: .failed("Ошибка захвата"),
                                      microphone: .stopped, system: .failed)
        #expect(!model.isRecording && !model.iconRecording)
        #expect(model.buttonTitle == "!")
        #expect(model.tracksLine.contains("ошибка"))
        #expect(model.startStopTitle == "Повторить запись")
    }

    @Test func durationIsVisibleInStatusBarButton() {
        let live = RecordingState.Live(id: "m", startedAt: t0, isManual: true)
        let model = MenuBarModel.from(live: live, now: t0.addingTimeInterval(65), phase: .recording)
        #expect(model.buttonTitle == "01:05")
        #expect(model.tracksLine == "Микрофон: готов · Системный звук: готов")
    }
}
