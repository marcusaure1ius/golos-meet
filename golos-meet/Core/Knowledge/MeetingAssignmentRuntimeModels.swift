import Foundation

nonisolated enum MeetingAssignmentWorkState: String, Sendable {
    case pending, running, current, waiting, failed, cancelled, manual
}
nonisolated struct MeetingAssignmentWork: Sendable, Equatable {
    let meetingID: String
    let input: String
    let generation: String
    let state: MeetingAssignmentWorkState
    let message: String
}
nonisolated struct MeetingAssignmentLease: Sendable { let work: MeetingAssignmentWork }
nonisolated struct MeetingAssignmentRuntimeSnapshot: Sendable {
    var revision: UInt64 = 0
    var work: [String: MeetingAssignmentWork] = [:]
    var decisions: [String: MeetingAssignmentDecision] = [:]
    var message: String?
}
nonisolated struct MeetingAssignmentInputs: Sendable {
    let checkpoint: MeetingAssignmentCheckpoint
    let fingerprints: [String: String]
}
