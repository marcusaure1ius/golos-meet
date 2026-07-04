import Testing
import Foundation
@testable import golos_meet

private final class SpyDelegate: MeetingDetectorDelegate {
    var starts: [Date] = []; var ends: [Date] = []; var manuals: [Bool] = []
    func meetingStarted(at d: Date, manual: Bool) -> Bool { starts.append(d); manuals.append(manual); return true }
    func meetingEnded(at d: Date) { ends.append(d) }
}

@Suite struct MeetingDetectorTests {
    // 1. Первый active → meetingStarted
    @Test func startsOnFirstActive() {
        let spy = SpyDelegate()
        let det = MeetingDetector(graceSeconds: 5)
        det.delegate = spy
        let t0 = Date(timeIntervalSince1970: 0)
        det.handle(active: true, at: t0)
        #expect(spy.starts.count == 1)
        #expect(spy.ends.count == 0)
    }

    // 2. Повторный active не перезапускает
    @Test func repeatedActiveNoSecondStart() {
        let spy = SpyDelegate()
        let det = MeetingDetector(graceSeconds: 5)
        det.delegate = spy
        let t0 = Date(timeIntervalSince1970: 0)
        det.handle(active: true, at: t0)
        det.handle(active: true, at: t0.addingTimeInterval(1))
        #expect(spy.starts.count == 1)
    }

    // 3. Тишина >= grace → meetingEnded (граница включительно)
    @Test func silenceBeyondGraceEnds() {
        let spy = SpyDelegate()
        let det = MeetingDetector(graceSeconds: 5)
        det.delegate = spy
        let t0 = Date(timeIntervalSince1970: 0)
        det.handle(active: true, at: t0)
        det.handle(active: false, at: t0.addingTimeInterval(5))
        #expect(spy.ends.count == 1)
    }

    // 4. Тишина < grace → не завершается
    @Test func silenceWithinGraceDoesNotEnd() {
        let spy = SpyDelegate()
        let det = MeetingDetector(graceSeconds: 5)
        det.delegate = spy
        let t0 = Date(timeIntervalSince1970: 0)
        det.handle(active: true, at: t0)
        det.handle(active: false, at: t0.addingTimeInterval(4))
        #expect(spy.ends.count == 0)
    }

    // 5. Активность сбрасывает таймер grace
    @Test func activityResetsGraceTimer() {
        let spy = SpyDelegate()
        let det = MeetingDetector(graceSeconds: 5)
        det.delegate = spy
        let t0 = Date(timeIntervalSince1970: 0)
        det.handle(active: true, at: t0)
        det.handle(active: true, at: t0.addingTimeInterval(3))   // обновляет lastActiveAt → t0+3
        det.handle(active: false, at: t0.addingTimeInterval(7))  // 4s с t0+3 → ещё не grace
        #expect(spy.ends.count == 0)
        det.handle(active: false, at: t0.addingTimeInterval(8))  // 5s с t0+3 → grace истёк
        #expect(spy.ends.count == 1)
    }

    // 6. После окончания детектор перевооружается
    @Test func reArmsAfterEnd() {
        let spy = SpyDelegate()
        let det = MeetingDetector(graceSeconds: 5)
        det.delegate = spy
        let t0 = Date(timeIntervalSince1970: 0)
        det.handle(active: true, at: t0)
        det.handle(active: false, at: t0.addingTimeInterval(5))  // ends==1
        #expect(spy.ends.count == 1)
        det.handle(active: true, at: t0.addingTimeInterval(6))   // starts==2
        #expect(spy.starts.count == 2)
    }

    // 7. inactive до любой активности игнорируется
    @Test func inactiveBeforeMeetingIgnored() {
        let spy = SpyDelegate()
        let det = MeetingDetector(graceSeconds: 5)
        det.delegate = spy
        let t0 = Date(timeIntervalSince1970: 0)
        det.handle(active: false, at: t0)
        #expect(spy.ends.count == 0)
    }
}
