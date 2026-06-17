import Foundation

/// Папка одной встречи на диске: `meetings/<id>/`, где id — таймстемп старта.
struct MeetingFolder {
    let id: String
    let url: URL
    let source: String

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func make(startedAt: Date, source: String) -> MeetingFolder {
        let id = formatter.string(from: startedAt)
        return MeetingFolder(id: id, url: AppPaths.meetingDir(id), source: source)
    }
}
