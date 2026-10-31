import Foundation
import Combine

/// Production composition is guarded before any AppPaths/library access. The
/// app owns one instance, including when no window or relevant tab is visible.
@MainActor enum ProductionIndexing {
    static let shared: KnowledgeIndexing? = {
        guard !AppRuntime.isTestHost else { return nil }
        let models = AppPaths.appSupport.appendingPathComponent("embedding-models")
        let installer = EmbeddingModelInstaller(root: models)
        let service = LocalIndexingService(store: ProjectLibrary.shared.store, meetingsRoot: AppPaths.meetingsRoot,
            inspect: { try await LocalEmbeddingCandidate.installed(using: installer) })
        return KnowledgeIndexing(service: service, installer: installer,
                                 roots: (AppPaths.meetingsRoot, models), center: .default)
    }()
}

@MainActor final class KnowledgeIndexing: ObservableObject {
    @Published private(set) var snapshot = LocalIndexingSnapshot()
    @Published private(set) var monitorMessage: String?
    let service: LocalIndexingService
    let installer: EmbeddingModelInstaller
    private let roots: (meetings: URL, models: URL)?
    private var subscription: KnowledgeIndexSubscription?
    private var monitor: KnowledgeFileMonitor?
    private var updates: Task<Void, Never>?
    private var fallback: Task<Void, Never>?
    private var started = false

    init(service: LocalIndexingService, installer: EmbeddingModelInstaller,
         roots: (meetings: URL, models: URL)? = nil, center: NotificationCenter? = nil) {
        self.service = service; self.installer = installer; self.roots = roots
        if let center {
            subscription = KnowledgeIndexSubscription(center: center) { [weak self] change in
                Task { @MainActor [weak self] in self?.receive(change) }
            }
        }
    }
    func start() {
        guard !started else { return }
        started = true
        updates = Task { [weak self, service] in
            let stream = await service.updates()
            await service.start()
            for await value in stream {
                guard !Task.isCancelled, let self else { break }
                if value.revision >= self.snapshot.revision { self.snapshot = value }
            }
        }
        if let roots {
            do {
                for root in [roots.meetings, roots.models] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
                monitor = try KnowledgeFileMonitor(roots: [roots.meetings, roots.models]) { [service] paths in
                    Task { await service.filesChanged(paths, modelsRoot: roots.models) }
                }
            } catch { monitorMessage = "Наблюдение за файлами недоступно. Библиотека проверяется периодически." }
            fallback = Task { [service] in
                var pointer = try? Data(contentsOf: roots.models.appendingPathComponent("active.json"))
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                    await service.changed()
                    let current = try? Data(contentsOf: roots.models.appendingPathComponent("active.json"))
                    if current != pointer { pointer = current; await service.modelChanged() }
                }
            }
        }
    }
    func stop() {
        started = false; monitor?.stop(); monitor = nil
        updates?.cancel(); updates = nil; fallback?.cancel(); fallback = nil
        Task { await service.stop() }
    }
    func receive(_ change: KnowledgeIndexChange) {
        start()
        Task {
            switch change {
            case .document(let id): await service.changed(source: .init(kind: .document, externalID: id.uuidString))
            case .meeting(let id), .removedMeeting(let id): await service.changed(source: .init(kind: .meeting, externalID: id))
            case .model: await service.modelChanged()
            case .projects: break
            }
        }
    }
    func refresh() { receive(.model); Task { await service.changed() } }
    func cancel(_ key: EmbeddingSourceKey) { Task { await service.cancel(key) } }
    func retry(_ key: EmbeddingSourceKey) { Task { await service.retry(key) } }
    func retryAll() { Task { await service.retryAll() } }
    func cancelAll() { Task { await service.cancelAll() } }
    func title(_ key: EmbeddingSourceKey) -> String {
        snapshot.titles[key] ?? (key.kind == .meeting ? "Встреча \(key.externalID)" : "Документ")
    }
    deinit {
        updates?.cancel(); fallback?.cancel(); monitor?.stop()
        let service = service
        Task { await service.stop() }
    }
}
