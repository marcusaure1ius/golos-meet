import Foundation

/// These values cross extraction/indexing queues; they do not own UI state.
nonisolated enum ProjectCloudPolicy: String, Codable, CaseIterable, Sendable {
    case localOnly
    case askEveryTime
    case allowSelectedContext

    func permitsGeneration(approvedForThisRequest: Bool = false) -> Bool {
        switch self {
        case .localOnly: return false
        case .askEveryTime: return approvedForThisRequest
        case .allowSelectedContext: return true
        }
    }
}

nonisolated struct KnowledgeProject: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var cloudPolicy: ProjectCloudPolicy

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil,
         cloudPolicy: ProjectCloudPolicy = .localOnly) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.cloudPolicy = cloudPolicy
    }
}

/// Page numbers are one-based. Times are seconds from the start of a meeting.
nonisolated struct KnowledgeLocation: Codable, Equatable, Sendable {
    var page: Int? = nil
    var paragraph: Int? = nil
    var startSeconds: Double? = nil
    var endSeconds: Double? = nil
}

nonisolated struct ExtractedTextBlock: Codable, Equatable, Sendable {
    let text: String
    var location: KnowledgeLocation = .init()
}

nonisolated struct ExtractedDocument: Equatable, Sendable {
    let title: String
    let contentHash: String
    let blocks: [ExtractedTextBlock]
    var warnings: [String] = []
}

nonisolated struct KnowledgeChunk: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceID: UUID
    let revision: String
    let ordinal: Int
    let text: String
    let location: KnowledgeLocation
}

/// Shared sources must obey the policy of every owning project. Missing policy
/// information denies egress; approval belongs to one request and is not persisted.
nonisolated enum KnowledgeEgress {
    static func permitsGeneration(ownerProjectIDs: Set<UUID>, projects: [KnowledgeProject],
                                  approvedProjectIDs: Set<UUID> = []) -> Bool {
        guard !ownerProjectIDs.isEmpty else { return false }
        let policies = Dictionary(projects.map { ($0.id, $0.cloudPolicy) },
                                  uniquingKeysWith: { _, latest in latest })
        return ownerProjectIDs.allSatisfy { id in
            policies[id]?.permitsGeneration(approvedForThisRequest: approvedProjectIDs.contains(id)) == true
        }
    }
}
