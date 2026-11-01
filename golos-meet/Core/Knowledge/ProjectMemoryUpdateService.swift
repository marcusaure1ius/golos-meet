import Foundation

/// The selected raw fragments and derived text are immutable for one request.
/// Full inherited sources are local proof, not implicitly sent raw text.
nonisolated struct MemoryUpdateRequest: Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let fragments: [KnowledgeSearchHit]
    let parents: [MemoryEvent]
    let consumedSources: [MemorySourceReference]
    let checkpoint: MemoryUpdateCheckpoint
    let payload: String
    fileprivate let lease: MemoryLease
    fileprivate let validation: MemoryUpdateGuard
    fileprivate init(id: UUID, projectID: UUID, fragments: [KnowledgeSearchHit], lease: MemoryLease,
                     validation: MemoryUpdateGuard, payload: String) {
        self.id = id; self.projectID = projectID; self.fragments = fragments; parents = lease.parents
        consumedSources = lease.sources; checkpoint = validation.checkpoint; self.payload = payload
        self.lease = lease; self.validation = validation
    }
    var ownerProjectIDs: Set<UUID> { Set(checkpoint.projects.map(\.id)) }
    var approvalProjectIDs: Set<UUID> { Set(checkpoint.projects.filter { $0.cloudPolicy == .askEveryTime }.map(\.id)) }
    var denied: Bool { checkpoint.projects.contains { $0.cloudPolicy == .localOnly } }
}
nonisolated struct MemoryUpdateConsent: Sendable {
    fileprivate let id: UUID
    fileprivate let requestID: UUID
}

/// One extraction session, injected local stores and ChatCompleter only. Durable
/// queue, production hooks, settings/Keychain and the panel are separate work.
@MainActor final class ProjectMemoryUpdateService {
    private let store: ProjectStore
    private let history: ProjectMemoryHistoryService
    private let reader: KnowledgeSearchSourceReader
    private let client: ChatCompleter
    private let model: String
    private let now: () -> Date
    private var currentID: UUID?
    private var pending: MemoryUpdateRequest?
    private var issuedConsent: MemoryUpdateConsent?
    private var operation: Task<MemoryUpdateOutcome, Error>?
    private(set) var state: MemoryUpdateState = .idle

    init(store: ProjectStore, meetingsRoot: URL, documentsRoot: URL, client: ChatCompleter,
         model: String, now: @escaping () -> Date = Date.init) {
        self.store = store; self.client = client; self.model = model; self.now = now
        history = .init(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
        reader = .init(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
    }
    func cancel() {
        operation?.cancel(); operation = nil
        currentID = nil; pending = nil; issuedConsent = nil; state = .cancelled
    }
    func prepare(projectID: UUID, hits: [KnowledgeSearchHit], parentEventIDs: [UUID] = [], queue: MemoryQueueLease? = nil) async throws -> MemoryUpdateRequest {
        cancel(); let id = UUID(); currentID = id; state = .preparing
        do {
            guard hits.count <= 12, parentEventIDs.count <= 8 else { throw MemoryUpdateError.contextTooLarge }
            guard Set(parentEventIDs).count == parentEventIDs.count,
                  !hits.isEmpty || !parentEventIDs.isEmpty,
                  Set(hits.map(\.id)).count == hits.count,
                  hits.allSatisfy({ $0.scope == .project(projectID) && $0.source.owners.contains(projectID) }),
                  !model.isEmpty, model.count <= 256 else { throw MemoryUpdateError.invalidContext }
            guard hits.reduce(0, { $0 + $1.chunk.text.count + $1.source.title.count }) <= 16_000 else { throw MemoryUpdateError.contextTooLarge }
            if let queue {
                let expected = try await store.memoryQueueChunks(queue)
                try requireCurrent(id)
                guard projectID == queue.job.projectID, hits.map(\.chunk) == expected,
                      hits.allSatisfy({ $0.source.key == queue.job.source && $0.fileStamp == queue.fileStamp }) else { throw MemoryUpdateError.invalidContext }
            }
            // Reserve/fence provenance first. This provisional key is never
            // queried or published; bind the actual selected input below.
            let provenance = try await history.begin(projectID: projectID, producerKey: "memory-update-preparing", hits: hits, parentEventIDs: parentEventIDs)
            try requireCurrent(id)
            guard provenance.ownerProjectIDs.count <= 128 else { throw MemoryUpdateError.contextTooLarge }
            let captured = try await store.memoryUpdateInputs(provenance)
            let validation = MemoryUpdateGuard(hits: captured.hits, checkpoint: captured.checkpoint, queue: queue)
            try requireCurrent(id)
            guard let project = validation.checkpoint.projects.first(where: { $0.id == projectID }) else { throw MemoryUpdateError.stale }
            let payload = try MemoryFactExtractor.payload(project: project, hits: hits, parents: provenance.parents)
            let key = try MemoryFactExtractor.producerKey(model: model, payload: payload, hits: hits, parents: provenance.parents)
            let lease = provenance.bindingUpdateInput(key)
            if let queue { try await store.bindMemoryQueueInput(queue, memory: lease, guard: validation); try requireCurrent(id) }
            let request = MemoryUpdateRequest(id: id, projectID: projectID, fragments: hits, lease: lease, validation: validation, payload: payload)
            try await validate(request)
            pending = request
            state = request.denied ? .denied : request.approvalProjectIDs.isEmpty ? .ready : .needsConsent
            return request
        } catch {
            if currentID == id { state = Self.failureState(error) }; throw error
        }
    }
    func approve(_ supplied: MemoryUpdateRequest) async throws -> MemoryUpdateConsent {
        guard let request = pending, request.id == supplied.id else { throw MemoryUpdateError.invalidConsent }
        try await validate(request)
        guard pending?.id == request.id else { throw MemoryUpdateError.invalidConsent }
        guard !request.denied else { throw KnowledgeAnswerError.cloudNotAllowed }
        let consent = MemoryUpdateConsent(id: UUID(), requestID: request.id)
        issuedConsent = consent; return consent
    }
    func update(_ supplied: MemoryUpdateRequest, consent: MemoryUpdateConsent? = nil) async throws -> MemoryUpdateOutcome {
        try requireCurrent(supplied.id)
        guard let request = pending, request.id == supplied.id else { throw MemoryUpdateError.invalidConsent }
        pending = nil; let issued = issuedConsent; issuedConsent = nil
        do {
            guard !request.denied else { throw KnowledgeAnswerError.cloudNotAllowed }
            if let consent {
                guard consent.id == issued?.id, consent.requestID == request.id else { throw MemoryUpdateError.invalidConsent }
            } else if !request.approvalProjectIDs.isEmpty { throw MemoryUpdateError.consentRequired }
            state = .running
            let task = Task { try await self.perform(request) }; operation = task
            // Cancelling the caller also cancels the owned task. A session
            // cancel fences a noncooperative provider and SQLite's final check.
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try requireCurrent(request.id)
            operation = nil
            state = result == .insufficientEvidence ? .insufficientEvidence : .updated
            return result
        } catch {
            if currentID == request.id { operation = nil; state = Self.failureState(error) }; throw error
        }
    }
    private func perform(_ request: MemoryUpdateRequest) async throws -> MemoryUpdateOutcome {
        try await validate(request)
        if let replay = try await store.existingMemoryUpdate(request.lease, guard: request.validation) {
            try requireCurrent(request.id); return .published(replay)
        }
        guard KnowledgeEgress.permitsGeneration(ownerProjectIDs: request.ownerProjectIDs,
            projects: request.checkpoint.projects, approvedProjectIDs: request.approvalProjectIDs) else { throw KnowledgeAnswerError.cloudNotAllowed }
        let raw = try await client.complete(model: model, messages: MemoryFactExtractor.messages(payload: request.payload),
            responseFormat: MemoryFactExtractor.responseFormat, beforeSending: { [self] in try await self.validate(request) })
        try await validate(request)
        let drafts = try MemoryFactExtractor.decode(raw, hits: request.fragments, parents: request.parents)
        guard let drafts else {
            try await store.finishMemoryQueueWithoutFacts(request.lease, guard: request.validation)
            try requireCurrent(request.id); return .insufficientEvidence
        }
        // Files are checked once more by history; the exact index/model and
        // parent-memory guard is checked with lease/CAS inside the final COMMIT.
        do {
            let publication = try await history.publish(drafts, lease: request.lease, extractedAt: now(), updateGuard: request.validation)
            try requireCurrent(request.id)
            return .published(publication)
        } catch ProjectMemoryError.limited {
            // Publication has <=16 drafts and a previously bounded immutable
            // ancestry; this is the journal's active-candidate cap, not a retry.
            throw MemoryUpdateError.candidateLimit
        }
    }
    private func requireCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard currentID == id else { throw MemoryUpdateError.superseded }
    }
    private func validate(_ request: MemoryUpdateRequest) async throws {
        try requireCurrent(request.id)
        var checked: Set<EmbeddingSourceKey> = []
        for hit in request.validation.hits where checked.insert(hit.source.key).inserted {
            _ = try await reader.read(hit, includePDF: false); try requireCurrent(request.id)
        }
        var previous: [MemorySourceReference] = []
        if let queue = request.validation.queue { previous = try await store.memoryQueueProof(queue); try requireCurrent(request.id) }
        for ref in previous {
            guard try await reader.identity(ref.readerHit().source) == ref.fileStamp else { throw MemoryUpdateError.stale }
            try requireCurrent(request.id)
        }
        for hit in request.validation.hits {
            guard try await reader.identity(hit.source) == hit.fileStamp else { throw MemoryUpdateError.stale }
            try requireCurrent(request.id)
        }
        try await store.validateMemoryUpdate(request.lease, guard: request.validation)
        try requireCurrent(request.id)
    }
    private static func failureState(_ error: Error) -> MemoryUpdateState {
        if error is CancellationError { return .cancelled }
        if error as? KnowledgeAnswerError == .cloudNotAllowed { return .denied }
        if error as? ProjectMemoryError == .limited || error as? MemoryQueueError == .budget || error as? MemoryUpdateError == .candidateLimit { return .limited }
        if error as? MemoryUpdateError == .notReady || error as? MemoryQueueError == .notReady { return .waiting }
        if error as? MemoryUpdateError == .consentRequired { return .needsConsent }
        if error is KnowledgeSearchError || error as? MemoryQueueError == .stale || error as? MemoryUpdateError == .stale || error as? ProjectMemoryError == .stale || error as? ProjectMemoryError == .unavailable { return .stale }
        return .failed
    }
}
