import Testing
import Foundation
@testable import golos_meet

private final class Spy: MeetingDetectorDelegate {
    var starts: [Bool] = []   // manual-флаг каждого старта
    var ends = 0
    func meetingStarted(at _: Date, manual: Bool) -> Bool { starts.append(manual); return true }
    func meetingEnded(at _: Date) { ends += 1 }
}

@Suite struct MeetingDetectorManualTests {
    private func make() -> (MeetingDetector, Spy) {
        let d = MeetingDetector(graceSeconds: 5); let s = Spy(); d.delegate = s; return (d, s)
    }
    private let t0 = Date(timeIntervalSince1970: 0)

    @Test func forceStartFromIdleStartsManual() {
        let (d, s) = make()
        d.forceStart(at: t0)
        #expect(s.starts == [true]); #expect(s.ends == 0)
    }

    @Test func silenceDoesNotEndManualSession() {
        let (d, s) = make()
        d.forceStart(at: t0)
        d.handle(active: false, at: t0.addingTimeInterval(100))  // тишина > grace
        #expect(s.ends == 0)                                     // ручную не рвём
    }

    @Test func forceStopEndsManualSession() {
        let (d, s) = make()
        d.forceStart(at: t0)
        d.forceStop(at: t0.addingTimeInterval(10))
        #expect(s.ends == 1)
    }

    @Test func noAutoRestartUntilInactiveAfterStop() {
        let (d, s) = make()
        d.forceStart(at: t0)
        d.forceStop(at: t0.addingTimeInterval(10))
        d.handle(active: true, at: t0.addingTimeInterval(11))    // звук ещё длится
        #expect(s.starts == [true])                              // рестарта нет
        d.handle(active: false, at: t0.addingTimeInterval(12))   // пришёл спад
        d.handle(active: true, at: t0.addingTimeInterval(13))    // теперь можно
        #expect(s.starts == [true, false])
    }

    @Test func forceStartDuringActiveIsNoop() {
        let (d, s) = make()
        d.handle(active: true, at: t0)                           // авто-старт
        d.forceStart(at: t0.addingTimeInterval(1))               // уже идёт
        #expect(s.starts == [false])
    }

    @Test func forceStopEndsAutoSession() {
        let (d, s) = make()
        d.handle(active: true, at: t0)                           // авто-старт
        d.forceStop(at: t0.addingTimeInterval(1))
        #expect(s.ends == 1)
    }

    private final class ConfigurableSpy: MeetingDetectorDelegate {
        var shouldStart = true
        var starts: [Bool] = []   // manual-флаг каждой попытки старта
        var ends = 0
        func meetingStarted(at _: Date, manual: Bool) -> Bool { starts.append(manual); return shouldStart }
        func meetingEnded(at _: Date) { ends += 1 }
    }

    @Test func failedManualStartRollsBackAndAutoStillWorks() {
        let d = MeetingDetector(graceSeconds: 5)
        let spy = ConfigurableSpy(); spy.shouldStart = false; d.delegate = spy
        d.forceStart(at: t0)                    // ручной старт проваливается → откат латча
        #expect(spy.starts == [true])           // ручная попытка была
        spy.shouldStart = true
        d.handle(active: true, at: t0.addingTimeInterval(1))
        #expect(spy.starts == [true, false])    // авто-старт СОСТОЯЛСЯ — manualSession не заглушил детект
    }
}
