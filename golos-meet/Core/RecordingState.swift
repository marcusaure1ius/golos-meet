import Foundation
import Combine

/// Наблюдаемое состояние текущей записи для UI (меню-бар + живая карточка).
/// Синглтон по образцу `MeetingProcessor.shared`: `Recorder` пишет сюда на старте/финализации.
@MainActor
final class RecordingState: ObservableObject {
    static let shared = RecordingState()

    struct Live: Equatable {
        let id: String
        let startedAt: Date
        let isManual: Bool
    }

    @Published private(set) var live: Live?
    enum Phase: Equatable { case idle, starting, recording, stopping, failed(String) }
    enum Track { case microphone, system }
    enum TrackStatus: Equatable { case waiting, ready, stopped, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var microphone: TrackStatus = .stopped
    @Published private(set) var system: TrackStatus = .stopped

    func prepare() {
        live = nil
        microphone = .waiting
        system = .waiting
        phase = .starting
    }

    func ready(_ track: Track) {
        if track == .microphone { microphone = .ready } else { system = .ready }
    }

    func trackFailed(_ track: Track?) {
        if track == .microphone { microphone = .failed }
        else if track == .system { system = .failed }
        else {
            if microphone != .ready { microphone = .failed }
            if system != .ready { system = .failed }
        }
    }

    func stopping() { phase = .stopping }
    func stopped(_ track: Track) {
        if track == .microphone {
            if microphone != .failed { microphone = .stopped }
        } else if system != .failed { system = .stopped }
    }
    func fail(_ message: String) {
        live = nil
        if microphone != .failed { microphone = .stopped }
        if system != .failed { system = .stopped }
        phase = .failed(message)
    }

    func begin(id: String, startedAt: Date, isManual: Bool) {
        live = Live(id: id, startedAt: startedAt, isManual: isManual)
        microphone = .ready
        system = .ready
        phase = .recording
    }

    func end() {
        live = nil
        microphone = .stopped
        system = .stopped
        phase = .idle
    }
}
