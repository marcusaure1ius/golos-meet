import Foundation
import Combine

@MainActor enum ProductionAssignments {
    static let shared: KnowledgeAssignments? = {
        guard !AppRuntime.isTestHost, let indexing = ProductionIndexing.shared else { return nil }
        return KnowledgeAssignments(store: ProjectLibrary.shared.store, projects: ProjectLibrary.shared,
            indexing: indexing.service, meetingsRoot: AppPaths.meetingsRoot,
            documentsRoot: AppPaths.appSupport.appendingPathComponent("knowledge"), center: .default)
    }()
}

@MainActor final class KnowledgeAssignments: ObservableObject {
    @Published private(set) var snapshot = MeetingAssignmentRuntimeSnapshot()
    let worker: MeetingAssignmentWorker
    let evidence: MeetingAssignmentEvidenceReader
    private let projects: ProjectLibrary
    private let indexing: LocalIndexingService
    private var subscription: KnowledgeIndexSubscription?
    private var updates: Task<Void, Never>?
    private var indexUpdates: Task<Void, Never>?
    private var fallback: Task<Void, Never>?
    private var started = false

    init(store: ProjectStore, projects: ProjectLibrary, indexing: LocalIndexingService,
         meetingsRoot: URL, documentsRoot: URL, center: NotificationCenter? = nil,
         worker: MeetingAssignmentWorker? = nil) {
        self.projects = projects; self.indexing = indexing
        self.worker = worker ?? MeetingAssignmentWorker(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
        evidence = MeetingAssignmentEvidenceReader(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
        if let center {
            subscription = KnowledgeIndexSubscription(center: center) { [weak self] _ in
                Task { @MainActor [weak self] in self?.changed() }
            }
        }
    }
    func start() {
        guard !started else { return }; started = true
        updates = Task { [weak self, worker] in
            let stream = await worker.updates()
            await worker.start()
            for await value in stream {
                guard !Task.isCancelled, let self else { break }
                guard value.revision >= snapshot.revision else { continue }
                let refreshProjects = snapshot.work != value.work || snapshot.decisions != value.decisions
                snapshot = value
                if refreshProjects { await projects.reload() }
            }
        }
        indexUpdates = Task { [indexing, worker] in
            let stream = await indexing.updates()
            for await value in stream {
                guard !Task.isCancelled else { break }
                await worker.setIndexAvailable(value.hasWorkingModel)
                await worker.changed()
            }
        }
        fallback = Task { [worker] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                await worker.changed()
            }
        }
    }
    func changed() { start(); Task { await worker.changed() } }
    func cancel(_ id: String) { Task { await worker.cancel(id) } }
    func retry(_ id: String) { Task { await worker.retry(id) } }
    func stop() {
        started = false
        updates?.cancel(); updates = nil; indexUpdates?.cancel(); indexUpdates = nil; fallback?.cancel(); fallback = nil
        Task { await worker.stop() }
    }
    deinit {
        updates?.cancel(); indexUpdates?.cancel(); fallback?.cancel()
        let worker = worker; Task { await worker.stop() }
    }
}
