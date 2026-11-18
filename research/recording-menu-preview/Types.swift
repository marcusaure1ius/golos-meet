import Foundation

// Build-time stand-ins only. The harness never links Recorder or app runtime.
enum RecordingState {
    struct Live {
        let id: String
        let startedAt: Date
        let isManual: Bool
    }
    enum Phase: Equatable { case idle, starting, recording, stopping, failed(String) }
    enum TrackStatus: Equatable { case waiting, ready, stopped, failed }
}
