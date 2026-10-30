import Foundation
import os

protocol MeetingDetectorDelegate: AnyObject {
    /// true means startup was accepted. Recorder publishes backend readiness
    /// separately and calls captureFailed if asynchronous startup later fails.
    func meetingStarted(at: Date, manual: Bool) -> Bool
    func meetingEnded(at: Date)
}

/// Превращает поток сигналов аудио-активности Толка в события встречи с grace-окном на спад.
/// active=true → встреча идёт; стоп — только если активности нет непрерывно ≥ graceSeconds.
final class MeetingDetector {
    weak var delegate: MeetingDetectorDelegate?
    private let graceSeconds: TimeInterval
    private var isMeeting = false
    private var manualSession = false
    private var suppressUntilInactive = false
    private var lastActiveAt: Date?

    init(graceSeconds: TimeInterval = 30) { self.graceSeconds = graceSeconds }

    func handle(active: Bool, at date: Date) {
        // Ручная сессия: авто-сигналы её не трогают (ни старт, ни стоп по тишине).
        if manualSession { return }
        if active {
            if suppressUntilInactive { return }   // ждём спада перед авто-рестартом
            lastActiveAt = date
            if !isMeeting {
                isMeeting = true
                Log.detector.info("meetingStarted")
                if delegate?.meetingStarted(at: date, manual: false) != true {
                    isMeeting = false   // запись не поднялась — повторим на следующем сигнале
                }
            }
        } else {
            suppressUntilInactive = false          // пришёл спад — блок авто-рестарта снят
            guard isMeeting, let last = lastActiveAt else { return }
            if date.timeIntervalSince(last) >= graceSeconds {
                isMeeting = false
                Log.detector.info("meetingEnded")
                delegate?.meetingEnded(at: date)
            }
        }
    }

    /// Ручной старт: форсит встречу, если её нет. Иначе no-op.
    func forceStart(at date: Date) {
        guard !isMeeting else { return }
        isMeeting = true
        manualSession = true
        suppressUntilInactive = false
        lastActiveAt = date
        Log.detector.info("meetingStarted (manual)")
        if delegate?.meetingStarted(at: date, manual: true) != true {
            // старт не удался — полный откат, иначе manualSession навсегда заглушит и авто-детект.
            isMeeting = false
            manualSession = false
        }
    }

    /// Ручной стоп: завершает текущую встречу (ручную или авто) и блокирует
    /// мгновенный авто-рестарт до ближайшего спада активности.
    func forceStop(at date: Date) {
        guard isMeeting else { return }
        isMeeting = false
        manualSession = false
        suppressUntilInactive = true
        Log.detector.info("meetingEnded (manual)")
        delegate?.meetingEnded(at: date)
    }

    /// An asynchronous capture failure releases manual/meeting state. Avoid
    /// repeated permission/start failures until inactivity or a new manual start.
    func captureFailed() {
        isMeeting = false
        manualSession = false
        lastActiveAt = nil
        suppressUntilInactive = true
    }
}
