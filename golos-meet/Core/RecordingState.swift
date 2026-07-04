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

    func begin(id: String, startedAt: Date, isManual: Bool) {
        live = Live(id: id, startedAt: startedAt, isManual: isManual)
    }

    func end() { live = nil }
}
