import Foundation

enum Speaker: String, Codable, Equatable {
    case me
    case participants

    /// Подпись для отображения (RU).
    var displayName: String {
        switch self {
        case .me: return "я"
        case .participants: return "участники"
        }
    }
}

struct TranscriptSegment: Codable, Equatable {
    let start: Double
    let end: Double
    let speaker: Speaker
    let text: String
}

struct Transcript: Codable, Equatable {
    let meetingId: String
    let asrModel: String
    let segments: [TranscriptSegment]
}
