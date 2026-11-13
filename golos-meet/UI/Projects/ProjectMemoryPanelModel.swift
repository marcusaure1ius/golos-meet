import Foundation
import Combine

nonisolated struct MemoryPanelEntry: Identifiable, Sendable {
    let entry: MemoryHistoryEntry
    let head: MemoryHead?
    let ancestry: MemoryEvidenceState
    var id: UUID { entry.event.id }
    var usable: Bool { head?.usableAsCurrent == true && ancestry == .current }
}

/// Read-only panel state for project memory. This first part renders the
/// overview, paged history, queue states and provenance; no consent or manual
/// write actions are wired yet. Every display round-trip is fenced by the
/// read-only store stamp so a panel never renders unconfirmed data as current.
@MainActor final class ProjectMemoryPanelModel: ObservableObject {
    @Published var projectID: UUID? { didSet { if oldValue != projectID { invalidate(); reload() } } }
    @Published var filter = "" { didSet { if oldValue != filter { invalidateActions() } } }
    @Published private(set) var projects: [KnowledgeProject] = []
    @Published private(set) var sourceTitles: [EmbeddingSourceKey:String] = [:]
    @Published private(set) var sourceOwners: [EmbeddingSourceKey:Set<UUID>] = [:]
    @Published private(set) var allowedProjects: Set<UUID>?
    @Published private(set) var heads: [MemoryPanelEntry] = []
    @Published private(set) var history: [MemoryPanelEntry] = []
    @Published private(set) var queue = MemoryQueueSnapshot()
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var stale = false
    @Published private(set) var headsLimited = false
    @Published private(set) var older: Int64?
    @Published private(set) var page: Int64?
    @Published private(set) var inspected: MemoryProvenance?
    @Published private(set) var inspectedState: MemoryEvidenceState?
    @Published private(set) var relatedEvents: [MemoryEvent] = []
    @Published private(set) var retiredEvents: Set<UUID> = []
    @Published private(set) var linksLimited = false
    @Published private(set) var destination: KnowledgeSearchDestination?
    @Published private(set) var enabled: Bool
    @Published private(set) var provider: String
    let meetingID: String?
    let worker: ProjectMemoryQueueWorker
    private let store: ProjectStore
    private let journal: ProjectMemoryHistoryService
    private let reader: KnowledgeSearchSourceReader
    private var generation = UUID()
    private var operation: Task<Void,Never>?
    private var watching: Task<Void,Never>?
    private var polling: Task<Void,Never>?
    private var subscription: KnowledgeIndexSubscription?
    private var configuration: AnyCancellable?
    private var stamp: String?
    private var watchedSources: [MemorySourceReference] = []
    private var watchedIdentities: [String:String] = [:]
    private var active = false

    init(store: ProjectStore, worker: ProjectMemoryQueueWorker, meetingsRoot: URL, documentsRoot: URL,
         projectID: UUID? = nil, meetingID: String? = nil, enabled: Bool = true, provider: String = "OpenRouter",
         center: NotificationCenter? = nil, configuration: AnyPublisher<(Bool,String),Never>? = nil) {
        self.store = store; self.worker = worker; self.projectID = projectID; self.meetingID = meetingID
        self.enabled = enabled; self.provider = provider
        journal = .init(store:store,meetingsRoot:meetingsRoot,documentsRoot:documentsRoot)
        reader = .init(store:store,meetingsRoot:meetingsRoot,documentsRoot:documentsRoot)
        if let center {
            subscription = KnowledgeIndexSubscription(center:center) { [weak self] _ in
                Task { @MainActor [weak self] in guard let self, active else { return }; invalidate(); reload() }
            }
        }
        self.configuration = configuration?.sink { [weak self] value in
            guard let self else { return }
            if self.enabled != value.0 || self.provider != value.1 {
                self.enabled = value.0; self.provider = value.1; invalidateActions(); if active { reload() }
            }
        }
    }
    var visibleHeads: [MemoryPanelEntry] { heads.filter { matches($0.entry.event) } }
    var visibleHistory: [MemoryPanelEntry] { history.filter { matches($0.entry.event) } }
    private func matches(_ event: MemoryEvent) -> Bool {
        filter.isEmpty || (event.statement.text + " " + event.statement.subject).localizedCaseInsensitiveContains(filter)
    }
    func start() {
        guard !active else { return }; active = true; reload()
        watching = Task { [weak self,worker] in
            for await _ in worker.updates() {
                guard !Task.isCancelled, let self, active else { break }
                if !busy && !loading { await changedIfNeeded() }
                if let project = projectID {
                    let token = generation
                    let latest = projectQueue(project)
                    guard active, !Task.isCancelled, token == generation, projectID == project else { continue }
                    queue = latest
                }
            }
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(2)) } catch { break }
                guard let self, active else { break }; if !busy && !loading { await changedIfNeeded() }
            }
        }
    }
    func close() { active = false; watching?.cancel(); polling?.cancel(); invalidateActions() }
    func invalidateActions() {
        generation = UUID(); operation?.cancel(); operation = nil; busy = false
        inspected = nil; inspectedState = nil; relatedEvents = []; retiredEvents = []; linksLimited = false; destination = nil
    }
    private func invalidate() { invalidateActions(); heads = []; history = []; queue = .init(); sourceTitles = [:]; sourceOwners = [:]; stale = true; stamp = nil; watchedSources = [] }
    func reload(before: Int64? = nil) {
        invalidateActions(); loading = true; notice = nil
        let id = generation, project = projectID
        operation = Task {
            do {
                let initial = try await store.memoryPanelStamp(), catalog = try await store.snapshot()
                try current(id)
                projects = catalog.projects; allowedProjects = meetingID.map { catalog.meetingProjects[$0] ?? [] }
                if let project, (!projects.contains { $0.id == project } || allowedProjects?.contains(project) == false) {
                    projectID = nil; return
                }
                if project == nil {
                    heads = []; history = []; queue = .init(); stamp = initial; stale = false; loading = false
                    if let allowedProjects, allowedProjects.count == 1 { projectID = allowedProjects.first }
                    return
                }
                guard let project else { return }
                let sourceCatalog = try await store.knowledgeSearchCatalog(scope:.project(project))
                var titles: [EmbeddingSourceKey:String] = [:]
                for source in sourceCatalog.sources { titles[source.key] = await reader.title(source) }
                let h = try await journal.heads(projectID:project,limit:50)
                let rows = try await journal.history(projectID:project,beforeSequence:before,limit:50)
                var checkedHeads:[MemoryPanelEntry] = [], checkedHistory:[MemoryPanelEntry] = []
                for head in h.heads {
                    let state = try await store.memoryPanelAncestryState(head.entry.event.id)
                    checkedHeads.append(.init(entry:head.entry,head:head,ancestry:state))
                }
                for row in rows.entries {
                    let state = try await store.memoryPanelAncestryState(row.event.id)
                    checkedHistory.append(.init(entry:row,head:nil,ancestry:state))
                }
                let work = projectQueue(project)
                let references = Array(Dictionary((h.heads.map(\.entry.event) + rows.entries.map(\.event)).flatMap(\.sources).map { (fileKey($0),$0) },uniquingKeysWith:{ a,_ in a }).values)
                var identities: [String:String] = [:], unavailable: Set<String> = []
                for source in references {
                    let key = fileKey(source), identity = (try? await reader.identity(source.readerHit().source)) ?? "unavailable"
                    identities[key] = identity
                    if identity != source.fileStamp { unavailable.insert(key) }
                }
                // Do not absorb a mutation between the history read and watch
                // registration as a new baseline while displaying current data.
                func checked(_ row:MemoryPanelEntry) -> MemoryPanelEntry {
                    .init(entry:row.entry,head:row.head,ancestry:row.entry.event.sources.contains { unavailable.contains(fileKey($0)) } ? .unconfirmed : row.ancestry)
                }
                guard try await store.memoryPanelStamp() == initial else { throw ProjectMemoryError.stale }
                try current(id)
                heads = checkedHeads.map(checked); history = checkedHistory.map(checked); queue = work
                sourceTitles = titles; sourceOwners = Dictionary(uniqueKeysWithValues:sourceCatalog.sources.map { ($0.key,$0.owners) }); headsLimited = h.limited
                older = rows.nextBeforeSequence; page = before; stamp = initial; stale = false; loading = false
                watchedSources = references; watchedIdentities = identities
            } catch { if generation == id { fail(error,id:id); loading = false } }
        }
    }
    private func changedIfNeeded() async {
        let generationAtStart = generation
        do {
            let token = generation, latest = try await store.memoryPanelStamp()
            var changed = latest != stamp
            for source in watchedSources {
                if ((try? await reader.identity(source.readerHit().source)) ?? "unavailable") != watchedIdentities[fileKey(source)] { changed = true; break }
            }
            guard token == generation, !busy, !loading else { return }
            if changed { invalidate(); reload() }
        } catch {
            guard active, generationAtStart == generation else { return }
            invalidate(); notice = "Не удалось проверить актуальность памяти. Обновите панель."
        }
    }
    /// Read-only view of the durable queue limited to this project. The full
    /// snapshot keeps its own conservative limit; a project-scoped store filter
    /// arrives together with queue actions.
    private func projectQueue(_ project: UUID) -> MemoryQueueSnapshot {
        let full = worker.snapshot()
        return .init(jobs: full.jobs.filter { $0.projectID == project }, revision: full.revision,
                     message: full.message, backpressured: full.backpressured)
    }
    nonisolated private func fileKey(_ source:MemorySourceReference) -> String { source.key.rawValue + "|" + source.revision }
    private func current(_ id: UUID) throws { try Task.checkCancellation(); guard generation == id else { throw ProjectMemoryError.stale } }
    private func begin() -> UUID { invalidateActions(); busy = true; notice = nil; return generation }
    private func fail(_ error: Error, id: UUID) {
        guard generation == id else { return }
        invalidateActions()
        if error is CancellationError { notice = "Действие отменено." }
        else if error as? ProjectMemoryError == .stale || error as? MemoryUpdateError == .stale || error is KnowledgeSearchError {
            stale = true; heads = []; history = []; notice = "Источник или память изменились. Обновите панель и повторите действие заново."
        } else { notice = "Не удалось выполнить действие. Память сохранена; проверьте источник, разрешения и настройки, затем обновите панель." }
    }
    func inspect(_ event: MemoryEvent) {
        guard !busy, event.projectID == projectID,
              (heads + history).contains(where:{ $0.id == event.id }) else { return }
        loadProof(event)
    }
    func inspectRelated(_ event:MemoryEvent) {
        guard !busy, relatedEvents.contains(where:{ $0.id == event.id }) else { return }
        loadProof(event)
    }
    private func loadProof(_ event:MemoryEvent) {
        let id = begin()
        operation = Task {
            do {
                let token = try await store.memoryPanelStamp()
                let proof = try await journal.provenance(eventID:event.id)
                let statuses = try await store.memoryReadStatus(proof.events)
                let links = Set(statuses.flatMap { $0.superseded + $0.conflicts }).subtracting([event.id])
                var related:[MemoryEvent] = []
                for link in links.sorted(by:{ $0.uuidString < $1.uuidString }).prefix(32) {
                    related.append(try await store.memoryEvent(link)); try current(id)
                }
                let state = try await store.memoryPanelAncestryState(event.id)
                guard try await store.memoryPanelStamp() == token else { throw ProjectMemoryError.stale }
                try current(id)
                inspected = proof; inspectedState = state; relatedEvents = related; linksLimited = links.count > 32
                retiredEvents = Set(zip(proof.events,statuses).filter { !$0.1.superseded.isEmpty }.map { $0.0.id }); busy = false
            } catch { fail(error,id:id) }
        }
    }
    func open(_ source: MemorySourceReference) {
        guard !busy, inspected?.sources.contains(where:{ $0 == source }) == true else { return }
        // Preserve inspected ancestry while displaying a checked local source.
        let proof = inspected, state = inspectedState, related = relatedEvents, retired = retiredEvents, limited = linksLimited, id = begin()
        operation = Task {
            do {
                try await store.validateMemoryPanelSource(source); try current(id)
                let hit = source.readerHit(), value = try await reader.read(hit,includePDF:true)
                try await store.validateMemoryPanelSource(source); try current(id)
                inspected = proof; inspectedState = state; relatedEvents = related; retiredEvents = retired; linksLimited = limited
                destination = .init(hit:hit,chunks:value.chunks,pdf:value.pdf,checkedAt:Date()); busy = false
            } catch { fail(error,id:id) }
        }
    }
    func back() { destination = nil }
    func dismissDetails() { invalidateActions() }
    deinit { operation?.cancel(); watching?.cancel(); polling?.cancel() }
}
