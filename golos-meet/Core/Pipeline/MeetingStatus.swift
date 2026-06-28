import Foundation

enum MeetingStatus: String, Codable, Equatable {
    case recording
    case processing
    case ready
    case failed
    case discarded
}
