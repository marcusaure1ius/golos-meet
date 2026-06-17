import Testing
import Foundation
@testable import golos_meet

private final class SpyDelegate: MeetingDetectorDelegate {
    var starts: [Date] = []; var ends: [Date] = []
    func meetingStarted(at d: Date) { starts.append(d) }
    func meetingEnded(at d: Date) { ends.append(d) }
}

@Suite struct MeetingDetectorTests {
    @Test func startThenEndEmitsOnce() {
        let spy = SpyDelegate(); let det = MeetingDetector(); det.delegate = spy
        let t0 = Date(timeIntervalSince1970: 0)
        det.handle(.inputActive, at: t0)
        det.handle(.inputInactive, at: t0.addingTimeInterval(60))
        #expect(spy.starts.count == 1)
        #expect(spy.ends.count == 1)
    }

    @Test func repeatedActiveDoesNotRestart() {
        let spy = SpyDelegate(); let det = MeetingDetector(); det.delegate = spy
        let t0 = Date(timeIntervalSince1970: 0)
        det.handle(.inputActive, at: t0)
        det.handle(.inputActive, at: t0.addingTimeInterval(5))   // дубль
        #expect(spy.starts.count == 1)
    }

    @Test func inactiveWithoutActiveIsIgnored() {
        let spy = SpyDelegate(); let det = MeetingDetector(); det.delegate = spy
        det.handle(.inputInactive, at: Date())
        #expect(spy.ends.isEmpty)
    }

    @Test func reArmsAfterCompleteCycle() {
        let spy = SpyDelegate(); let det = MeetingDetector(); det.delegate = spy
        let t0 = Date(timeIntervalSince1970: 0)
        det.handle(.inputActive, at: t0)
        det.handle(.inputInactive, at: t0.addingTimeInterval(60))
        det.handle(.inputActive, at: t0.addingTimeInterval(90))
        #expect(spy.starts.count == 2)
        #expect(spy.ends.count == 1)
    }
}
