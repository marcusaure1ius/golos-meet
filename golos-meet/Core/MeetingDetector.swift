import Foundation
import os

enum MeetingSignal { case inputActive, inputInactive }

protocol MeetingDetectorDelegate: AnyObject {
    func meetingStarted(at: Date)
    func meetingEnded(at: Date)
}

/// Чистая логика: переводит поток сигналов «Толк держит/отпустил вход» в события встречи.
/// Mute не рвёт встречу (R-8a): стоп — только реальный inputInactive после активной встречи.
final class MeetingDetector {
    weak var delegate: MeetingDetectorDelegate?
    private var isMeeting = false

    func handle(_ signal: MeetingSignal, at date: Date) {
        switch signal {
        case .inputActive:
            guard !isMeeting else { return }
            isMeeting = true
            Log.detector.info("meetingStarted")
            delegate?.meetingStarted(at: date)
        case .inputInactive:
            guard isMeeting else { return }
            isMeeting = false
            Log.detector.info("meetingEnded")
            delegate?.meetingEnded(at: date)
        }
    }
}
