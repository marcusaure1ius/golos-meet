import Foundation
import Combine

@MainActor enum ProductionMemoryQueue {
    static let shared: KnowledgeMemoryQueue? = {
        // Guard MUST precede every real shared store/settings/runtime/key path.
        guard !AppRuntime.isTestHost, let indexing = ProductionIndexing.shared else { return nil }
        let settings = UISettings.shared
        let worker = ProjectMemoryQueueWorker(store: ProjectLibrary.shared.store, meetingsRoot: AppPaths.meetingsRoot,
            documentsRoot: AppPaths.appSupport.appendingPathComponent("knowledge"), client: QuestionOpenRouterClient(), model: settings.llmModel)
        return KnowledgeMemoryQueue(worker: worker, center: .default, enabled: settings.llmEnabled, model: settings.llmModel,
            indexUpdates: { await indexing.service.updates() },
            configuration: settings.$llmEnabled.combineLatest(settings.$llmModel).eraseToAnyPublisher())
    }()
}

/// Metadata/index subscriptions only; recording and ASR never await this bridge.
/// Tests inject a unique NotificationCenter, actual temp worker and fake stream.
@MainActor final class KnowledgeMemoryQueue: ObservableObject {
    #if DEBUG
    nonisolated let diagnosticOwnerID = UUID()
    private nonisolated let diagnosticObserver = MemoryQueueDiagnostics.observer
    private var diagnosticConfigurationID: UUID?
    private var diagnosticStartReturnedID: UUID?
    // A controlled test may pause between changed() and the existing guard.
    // Nil by default; this hook and all observation disappear from Release.
    var diagnosticBeforeStart: (@MainActor (UUID) async -> Void)?
    func diagnosticSnapshot() -> [String: String] {
        let workerState = worker.diagnosticSnapshot()
        return ["workerRunID": workerState["runID"] ?? "", "workerStarted": workerState["started"] ?? "",
         "bridgeID": diagnosticOwnerID.uuidString, "workerID": worker.diagnosticOwnerID.uuidString,
         "configurationID": diagnosticConfigurationID?.uuidString ?? "",
         "startReturnedConfigurationID": diagnosticStartReturnedID?.uuidString ?? "",
         "started": String(started), "enabled": String(enabled), "model": model,
         "dirty": String(dirty), "revision": String(snapshot.revision)]
    }
    private func diagnostic(_ stage: String, configuration: UUID? = nil) {
        guard diagnosticObserver != nil else { return }
        var fields = diagnosticSnapshot()
        if let configuration { fields["configurationID"] = configuration.uuidString }
        MemoryQueueDiagnostics.record(diagnosticObserver, owner: diagnosticOwnerID, kind: "bridge", stage: stage, fields: fields)
    }
    #endif
    @Published private(set) var snapshot = MemoryQueueSnapshot()
    let worker: ProjectMemoryQueueWorker
    private let indexUpdates: (() async -> AsyncStream<LocalIndexingSnapshot>)?
    private var subscription: KnowledgeIndexSubscription?
    private var configuration: AnyCancellable?
    private var applyingConfiguration: Task<Void,Never>?
    private var updates: Task<Void,Never>?
    private var indexing: Task<Void,Never>?
    private var fallback: Task<Void,Never>?
    private var refresh: Task<Void,Never>?
    private var dirty = false
    private var started = false
    private var enabled: Bool
    private var model: String
    init(worker: ProjectMemoryQueueWorker, center: NotificationCenter? = nil, enabled: Bool = true, model: String,
         indexUpdates: (() async -> AsyncStream<LocalIndexingSnapshot>)? = nil,
         configuration: AnyPublisher<(Bool,String),Never>? = nil) {
        self.worker = worker; self.enabled = enabled; self.model = model; self.indexUpdates = indexUpdates
        #if DEBUG
        let owner = diagnosticOwnerID, observer = diagnosticObserver, workerOwner = worker.diagnosticOwnerID
        #endif
        if let center {
            subscription = KnowledgeIndexSubscription(center: center) { [weak self] _ in
                #if DEBUG
                MemoryQueueDiagnostics.record(observer, owner: owner, kind: "bridge", stage: "event.received",
                                              fields: ["workerID": workerOwner.uuidString])
                #endif
                Task { @MainActor [weak self] in
                    #if DEBUG
                    self?.diagnostic("event.main")
                    #endif
                    self?.changed()
                }
            }
        }
        self.configuration = configuration?.removeDuplicates(by: { $0.0 == $1.0 && $0.1 == $1.1 }).sink { [weak self] value in
            guard let self else { return }; self.enabled = value.0; self.model = value.1
            guard self.started else { return }
            self.applyConfiguration()
        }
    }
    func start() {
        #if DEBUG
        diagnostic("start.request")
        #endif
        guard !started else { return }; started = true
        updates = Task { [weak self, worker] in
            let stream = worker.updates()
            for await value in stream {
                guard !Task.isCancelled, let self else { break }
                if value.revision >= snapshot.revision { snapshot = value }
            }
        }
        applyConfiguration()
        if let indexUpdates {
            indexing = Task { [weak self] in
                let stream = await indexUpdates()
                for await _ in stream {
                    guard !Task.isCancelled, let self else { break }; changed()
                }
            }
        }
        fallback = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                self?.changed()
            }
        }
    }
    private func applyConfiguration() {
        applyingConfiguration?.cancel()
        #if DEBUG
        let configurationID = UUID()
        diagnosticConfigurationID = configurationID
        diagnostic("configuration.request", configuration: configurationID)
        #endif
        let requestedEnabled = enabled, requestedModel = model
        applyingConfiguration = Task { [weak self, worker] in
            guard let self, started, !Task.isCancelled else { return }
            if requestedEnabled {
                #if DEBUG
                diagnostic("configuration.changed.begin", configuration: configurationID)
                #endif
                await worker.changed(model: requestedModel)
                #if DEBUG
                diagnostic("configuration.changed.return", configuration: configurationID)
                if let gate = diagnosticBeforeStart { await gate(configurationID) }
                #endif
                // A newer disable/stop must win across the actor/file awaits.
                guard !Task.isCancelled, started, enabled, model == requestedModel else { return }
                #if DEBUG
                diagnostic("configuration.start.begin", configuration: configurationID)
                #endif
                await worker.start()
                #if DEBUG
                diagnosticStartReturnedID = configurationID
                diagnostic("configuration.start.return", configuration: configurationID)
                #endif
            } else { await worker.stop() }
        }
    }
    func changed() {
        #if DEBUG
        diagnostic("changed.request")
        #endif
        guard started, enabled else { return }; dirty = true
        guard refresh == nil else { return }
        refresh = Task { [weak self] in
            while let self, started, enabled, dirty, !Task.isCancelled {
                dirty = false
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                await worker.changed(model: model)
            }
            self?.refresh = nil
        }
    }
    func stop() {
        #if DEBUG
        diagnostic("stop.request")
        #endif
        started = false; dirty = false
        updates?.cancel(); updates = nil; indexing?.cancel(); indexing = nil; fallback?.cancel(); fallback = nil
        refresh?.cancel(); refresh = nil
        applyingConfiguration?.cancel()
        applyingConfiguration = Task { [worker] in
            guard !Task.isCancelled else { return }; await worker.stop()
        }
    }
    deinit {
        updates?.cancel(); indexing?.cancel(); fallback?.cancel(); refresh?.cancel(); applyingConfiguration?.cancel()
        #if DEBUG
        let owner = diagnosticOwnerID, observer = diagnosticObserver, workerOwner = worker.diagnosticOwnerID
        MemoryQueueDiagnostics.record(observer, owner: owner, kind: "bridge", stage: "deinit",
                                      fields: ["workerID": workerOwner.uuidString])
        let worker = worker
        Task { @MainActor in
            MemoryQueueDiagnostics.record(observer, owner: owner, kind: "bridge", stage: "deinit.stop.begin",
                                          fields: ["workerID": workerOwner.uuidString])
            await worker.stop()
            MemoryQueueDiagnostics.record(observer, owner: owner, kind: "bridge", stage: "deinit.stop.return",
                                          fields: ["workerID": workerOwner.uuidString])
        }
        #else
        let worker = worker; Task { @MainActor in await worker.stop() }
        #endif
    }
}
