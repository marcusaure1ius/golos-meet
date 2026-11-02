#if DEBUG
import Foundation

/// Opt-in test observation only. An instance captures its creating observer so
/// a late deinit cannot be attributed to the next task's scope. No source text.
nonisolated enum MemoryQueueDiagnostics {
    struct Event: Codable, Sendable {
        let ownerID: UUID
        let ownerKind: String
        let stage: String
        let uptime: Double
        let fields: [String: String]
    }
    @TaskLocal static var observer: (@Sendable (Event) -> Void)?
    static func record(_ observer: (@Sendable (Event) -> Void)?, owner: UUID, kind: String,
                       stage: String, fields: [String: String]) {
        observer?(.init(ownerID: owner, ownerKind: kind, stage: stage,
                        uptime: ProcessInfo.processInfo.systemUptime, fields: fields))
    }
}
#endif
