import Foundation
import Combine

nonisolated struct DocumentImportJob: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let projectIDs: Set<UUID>
    let targetID: UUID?
    var state: DocumentImportState = .queued
    var progress: Double? = nil
    var message = ""
    var cancelRequested = false
}

/// Only progress/state publication is on MainActor. Reading, parsing, OCR,
/// chunking and SQLite work run in independent actors, never in MeetingProcessor.
@MainActor
final class DocumentImportQueue: ObservableObject {
    @Published private(set) var jobs: [DocumentImportJob] = []
    @Published private(set) var completedCount = 0
    private let importer: DocumentImporter
    private let store: ProjectStore
    private let onImported: @Sendable (UUID) -> Void
    private var activeID: UUID?
    private var activeTask: Task<Void, Never>?

    init(importer: DocumentImporter, store: ProjectStore,
         onImported: @escaping @Sendable (UUID) -> Void = { KnowledgeIndexEvents.post(.document($0)) }) {
        self.importer = importer
        self.store = store
        self.onImported = onImported
    }

    func enqueue(urls: [URL], projectIDs: Set<UUID>, targetID: UUID? = nil) async {
        for url in urls {
            let job = DocumentImportJob(id: UUID(), url: url, projectIDs: projectIDs, targetID: targetID)
            jobs.append(job)
            do { try await store.startImport(id: job.id, filename: url.lastPathComponent, targetID: targetID, state: .queued) }
            catch { update(job.id) { $0.state = .failed; $0.message = DocumentImporter.userMessage(for: error) } }
        }
        startNext()
    }

    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.state.isTerminal else { return }
        if activeID == id {
            update(id) { $0.cancelRequested = true }
            activeTask?.cancel()
        } else {
            update(id) { $0.state = .cancelled; $0.message = "Импорт отменён." }
            Task { try? await store.updateImport(id: id, state: .cancelled, message: "Импорт отменён до начала обработки.") }
        }
    }

    func retry(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }), job.state.isTerminal else { return }
        await enqueue(urls: [job.url], projectIDs: job.projectIDs, targetID: job.targetID)
    }

    private func startNext() {
        guard activeTask == nil, let job = jobs.first(where: { $0.state == .queued }) else { return }
        activeID = job.id
        update(job.id) { $0.state = .copying }
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await importer.importFile(id: job.id, url: job.url, projectIDs: job.projectIDs, targetID: job.targetID) { [weak self] progress in
                    Task { @MainActor in self?.apply(progress, id: job.id) }
                }
                update(job.id) {
                    $0.state = .completed
                    $0.progress = 1
                    $0.message = result.reused ? "Уже в библиотеке. Повторная копия не добавлена." : "Документ и фрагменты сохранены локально."
                }
                completedCount += 1
                onImported(result.documentID)
            } catch {
                update(job.id) {
                    $0.state = error is CancellationError ? .cancelled : .failed
                    $0.message = error is CancellationError ? "Импорт отменён; предыдущая версия сохранена." : DocumentImporter.userMessage(for: error)
                }
            }
            activeID = nil
            activeTask = nil
            startNext()
        }
    }

    private func apply(_ progress: DocumentImportProgress, id: UUID) {
        guard activeID == id else { return }
        update(id) { job in
            guard !job.state.isTerminal, !job.cancelRequested, progress.state.order >= job.state.order else { return }
            let fraction: Double?
            if let total = progress.total, total > 0, let completed = progress.completed {
                fraction = min(1, Double(completed) / Double(total))
            } else { fraction = nil }
            if progress.state == job.state, let old = job.progress, let fraction, fraction < old { return }
            job.state = progress.state
            job.progress = fraction
        }
    }

    private func update(_ id: UUID, _ mutate: (inout DocumentImportJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }
}
