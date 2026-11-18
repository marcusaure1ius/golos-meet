import Foundation
import Combine

/// Metadata/index subscriptions only; recording and ASR never await this bridge.
/// Tests inject a unique NotificationCenter, actual temp worker and fake stream.
@MainActor final class KnowledgeMemoryQueue: ObservableObject {
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
        if let center {
            subscription = KnowledgeIndexSubscription(center: center) { [weak self] _ in
                Task { @MainActor [weak self] in Trace61.mark("bridge.event.main", "alive=\(self != nil)"); self?.changed() }
            }
        }
        self.configuration = configuration?.removeDuplicates(by: { $0.0 == $1.0 && $0.1 == $1.1 }).sink { [weak self] value in
            guard let self else { return }; self.enabled = value.0; self.model = value.1
            guard self.started else { return }
            self.applyConfiguration()
        }
    }
    func start() {
        Trace61.mark("bridge.start")
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
        let requestedEnabled = enabled, requestedModel = model
        applyingConfiguration = Task { [weak self, worker] in
            guard let self, started, !Task.isCancelled else { return }
            if requestedEnabled {
                Trace61.mark("config.changed.begin"); await worker.changed(model: requestedModel); Trace61.mark("config.changed.return"); await Hooks61.pauseStartup()
                // A newer disable/stop must win across the actor/file awaits.
                guard !Task.isCancelled, started, enabled, model == requestedModel else { return }
                Trace61.mark("config.start.begin"); await worker.start(); Hooks61.acked = true; Trace61.mark("config.start.ack")
            } else { await worker.stop() }
        }
    }
    func changed() {
        Trace61.mark("bridge.changed")
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
        Trace61.mark("bridge.stop")
        started = false; dirty = false
        updates?.cancel(); updates = nil; indexing?.cancel(); indexing = nil; fallback?.cancel(); fallback = nil
        refresh?.cancel(); refresh = nil
        applyingConfiguration?.cancel()
        applyingConfiguration = Task { [worker] in
            guard !Task.isCancelled else { return }; await worker.stop()
        }
    }
    deinit {
        Trace61.mark("bridge.deinit")
        updates?.cancel(); indexing?.cancel(); fallback?.cancel(); refresh?.cancel(); applyingConfiguration?.cancel()
        let worker = worker; Task { @MainActor in await worker.stop() }
    }
}
