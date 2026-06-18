import Foundation
import os

protocol MeetingDetectorDelegate: AnyObject {
    func meetingStarted(at: Date)
    func meetingEnded(at: Date)
}

/// Превращает поток сигналов аудио-активности Толка в события встречи с grace-окном на спад.
/// active=true → встреча идёт; стоп — только если активности нет непрерывно ≥ graceSeconds.
final class MeetingDetector {
    weak var delegate: MeetingDetectorDelegate?
    private let graceSeconds: TimeInterval
    private var isMeeting = false
    private var lastActiveAt: Date?

    init(graceSeconds: TimeInterval = 30) { self.graceSeconds = graceSeconds }

    func handle(active: Bool, at date: Date) {
        if active {
            lastActiveAt = date
            if !isMeeting {
                isMeeting = true
                Log.detector.info("meetingStarted")
                delegate?.meetingStarted(at: date)
            }
        } else {
            guard isMeeting, let last = lastActiveAt else { return }
            if date.timeIntervalSince(last) >= graceSeconds {
                isMeeting = false
                Log.detector.info("meetingEnded")
                delegate?.meetingEnded(at: date)
            }
        }
    }
}
