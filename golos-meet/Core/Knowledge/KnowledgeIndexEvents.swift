import Foundation

nonisolated enum KnowledgeIndexChange: Sendable {
    case document(UUID), meeting(String), removedMeeting(String), model
}

/// Process-local, fire-and-forget metadata signals. No text, audio or network.
nonisolated enum KnowledgeIndexEvents {
    static let name = Notification.Name("golos.knowledge-index-change")
    static func post(_ change: KnowledgeIndexChange, center: NotificationCenter = .default) {
        center.post(name: name, object: nil, userInfo: ["change": change])
    }
}

nonisolated final class KnowledgeIndexSubscription: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol
    init(center: NotificationCenter, receive: @escaping @Sendable (KnowledgeIndexChange) -> Void) {
        self.center = center
        token = center.addObserver(forName: KnowledgeIndexEvents.name, object: nil, queue: nil) { notification in
            if let change = notification.userInfo?["change"] as? KnowledgeIndexChange { receive(change) }
        }
    }
    deinit { center.removeObserver(token) }
}
