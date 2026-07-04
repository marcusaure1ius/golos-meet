import Testing
import Foundation
@testable import golos_meet

@Suite struct MenuBarModelTests {
    private let t0 = Date(timeIntervalSince1970: 0)

    @Test func idleWhenNoLive() {
        let m = MenuBarModel.from(live: nil, now: t0)
        #expect(m.isRecording == false)
        #expect(m.startStopTitle == "Начать запись")
        #expect(m.statusLine == "Автодетект активен")
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
}
