import Foundation
import CryptoKit

nonisolated enum ProjectMemoryError: Error, LocalizedError, Equatable {
    case invalid, stale, unavailable, limited, missing
    var errorDescription: String? {
        switch self {
        case .invalid: "Событие памяти или его происхождение не прошло проверку."
        case .stale: "Источники или версия памяти изменились. Подготовьте обработку заново."
        case .unavailable: "Источник памяти недоступен или больше не подтверждает сохранённую ревизию."
        case .limited: "Слишком много зависимостей для одной операции памяти. Разделите обработку."
        case .missing: "Событие памяти не найдено."
        }
    }
}
nonisolated enum MemoryFactKind: String, Codable, Sendable { case decision, agreement, deadline, openQuestion, completionClaim }
nonisolated enum MemoryAction: String, Codable, Sendable { case assertion, retraction }
nonisolated enum MemoryOrigin: String, Codable, Sendable { case model, manual }
nonisolated enum MemoryLinkKind: String, Codable, Sendable { case related, compatible, conflicts, replaces, retracts, corrects, derivedFrom }
nonisolated enum MemoryEvidenceState: String, Sendable { case current, stale, unconfirmed }

/// Structured input from a future extractor or explicit human action. This is
/// NOT a natural-language classifier. Equal conditions define comparable scope.
nonisolated struct MemoryStatement: Codable, Equatable, Sendable {
    let subject: String
    let kind: MemoryFactKind
    let conditions: [String: String]
    let text: String
    var deadline: MemoryDateRange? = nil
}
nonisolated struct MemoryDateRange: Codable, Equatable, Sendable {
    let earliest: Date
    let latest: Date
}
nonisolated struct MemoryExplicitLink: Codable, Equatable, Sendable {
    let targetID: UUID
    let kind: MemoryLinkKind
}
nonisolated struct MemoryDraft: Sendable {
    let statement: MemoryStatement
    let evidenceChunkIDs: Set<String>
    var decisionDate: Date? = nil
    var links: [MemoryExplicitLink] = []
    var action: MemoryAction = .assertion
}
nonisolated struct MemoryDocumentCopy: Codable, Equatable, Sendable {
    let versionID: UUID
    let contentHash: String
    let relativePath: String
    let originalName: String
    let importedAt: Date
}
/// Full selected input, not just the subset labelled as supporting evidence.
/// No source FK: history and original owners survive source deletion/recreate.
nonisolated struct MemorySourceReference: Codable, Equatable, Sendable {
    let key: EmbeddingSourceKey
    let generation: String
    let revision: String
    let title: String
    let chunk: KnowledgeChunk
    let ownerProjectIDs: [UUID]
    let fileStamp: String
    let document: MemoryDocumentCopy?
    let sourceDate: Date?

    init(hit: KnowledgeSearchHit) throws {
        guard let revision = hit.source.observation.revision, let stamp = hit.fileStamp else { throw ProjectMemoryError.invalid }
        key = hit.source.key; generation = hit.source.observation.generation; self.revision = revision
        title = hit.source.title; chunk = hit.chunk; fileStamp = stamp
        ownerProjectIDs = hit.source.owners.sorted { $0.uuidString < $1.uuidString }
        document = hit.source.document.map { .init(versionID: $0.id, contentHash: $0.contentHash,
            relativePath: $0.relativePath, originalName: $0.originalName, importedAt: $0.importedAt) }
        sourceDate = nil // search does not supply a verified source date; import is separate
    }
    var identity: String { key.rawValue + "|" + generation + "|" + revision + "|" + chunk.id }
    func readerHit() -> KnowledgeSearchHit {
        let copy = document.map { DocumentVersion(id: $0.versionID, documentID: key.chunkSourceID,
            contentHash: $0.contentHash, relativePath: $0.relativePath, originalName: $0.originalName,
            importedAt: $0.importedAt, warnings: [], chunkCount: 0) }
        // SourceReader validates bytes and chunks, not query/model/job state.
        // Store validates the durable source identity separately. Reindexing
        // unchanged bytes must not erase a human correction or its evidence.
        let source = KnowledgeSearchSource(observation: .init(key: key, generation: generation, revision: revision),
            job: .init(source: key, revision: revision, generation: "history", modelID: "", state: .ready, completed: 0, total: 0, message: ""),
            owners: Set(ownerProjectIDs), title: title, document: copy)
        return .init(source: source, chunk: chunk, model: .init(model: nil, generation: "history"),
                     scope: .all, matchedWords: true, matchedMeaning: false, fileStamp: fileStamp)
    }
}
nonisolated struct MemoryEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let origin: MemoryOrigin
    let action: MemoryAction
    let statement: MemoryStatement
    let evidenceChunkIDs: [String]
    let parentEventIDs: [UUID]
    let sources: [MemorySourceReference]
    let ownerProjectIDs: [UUID]
    let decisionDate: Date?
    let extractedAt: Date
}
nonisolated struct MemoryHistoryEntry: Sendable {
    let sequence: Int64
    let event: MemoryEvent
    let evidenceState: MemoryEvidenceState
    let supersededBy: [UUID]
}
nonisolated struct MemoryHistoryPage: Sendable {
    let entries: [MemoryHistoryEntry]
    let nextBeforeSequence: Int64?
}
nonisolated struct MemoryHead: Sendable {
    let version: Int64
    let entry: MemoryHistoryEntry
    let manualSelection: Bool
    let conflictingEventIDs: [UUID]
    var usableAsCurrent: Bool { entry.event.action == .assertion && entry.evidenceState == .current && entry.supersededBy.isEmpty && conflictingEventIDs.isEmpty }
}
nonisolated struct MemoryHeadsPage: Sendable {
    let heads: [MemoryHead]
    let limited: Bool
}
nonisolated struct MemoryProvenance: Sendable {
    let rootEventID: UUID
    let events: [MemoryEvent]
    let sources: [MemorySourceReference]
    let ownerProjectIDs: Set<UUID>
    let knownProjects: [KnowledgeProject]
    let missingOwnerProjectIDs: Set<UUID>
    let evidenceState: MemoryEvidenceState
}
nonisolated struct MemoryLease: Sendable {
    let projectID: UUID
    let producerKey: String
    let fingerprint: String
    let generation: String
    let baseRevision: Int
    let assignmentEpoch: String
    let origin: MemoryOrigin
    let manualTargetID: UUID?
    let parents: [MemoryEvent]
    let sources: [MemorySourceReference]
    let ownerProjectIDs: [UUID]
}
nonisolated enum MemoryPublication: Equatable, Sendable {
    case inserted([UUID]), unchanged([UUID])
    var eventIDs: [UUID] { switch self { case .inserted(let ids), .unchanged(let ids): ids } }
}

nonisolated enum MemoryEncoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(value.utf8))
    }
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func slot(_ statement: MemoryStatement) throws -> String {
        struct Identity: Encodable { let subject: String; let kind: MemoryFactKind; let conditions: [String: String] }
        return hash(try encode(Identity(subject: statement.subject, kind: statement.kind, conditions: statement.conditions)))
    }
    static func relation(_ a: MemoryStatement, _ b: MemoryStatement) -> MemoryLinkKind {
        guard a.subject == b.subject, a.kind == b.kind, a.conditions == b.conditions else { return .related }
        guard a.kind == .deadline, let x = a.deadline, let y = b.deadline else { return .related }
        return x.latest < y.earliest || y.latest < x.earliest ? .conflicts : .compatible
    }
}
