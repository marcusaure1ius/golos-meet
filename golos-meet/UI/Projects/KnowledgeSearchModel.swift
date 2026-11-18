import Foundation
import Combine

@MainActor enum ProductionKnowledgeSearch {
    static let service: KnowledgeSearchService? = {
        if AppRuntime.isTestHost {
            // UI-test shell (#105): живой поиск по пустому изолированному
            // хранилищу; семантика честно сообщает про отсутствие модели,
            // индексация и загрузка модели не запускаются.
            guard AppRuntime.uiTestShell else { return nil }
            return KnowledgeSearchService(store: ProjectLibrary.shared.store, meetingsRoot: AppPaths.meetingsRoot,
                documentsRoot: AppPaths.appSupport.appendingPathComponent("knowledge"),
                queryEmbedding: { _ in throw LocalIndexingError.missingModel })
        }
        guard let indexing = ProductionIndexing.shared else { return nil }
        let runtime = indexing.service
        return KnowledgeSearchService(store: ProjectLibrary.shared.store, meetingsRoot: AppPaths.meetingsRoot,
            documentsRoot: AppPaths.appSupport.appendingPathComponent("knowledge"),
            prepare: { try await runtime.synchronizeForSearch() }, queryEmbedding: { try await runtime.embedQuery($0) },
            sourceChanged: { await runtime.changed(source: $0) })
    }()
}

@MainActor final class KnowledgeSearchModel: ObservableObject {
    @Published var query = ""
    @Published var scope: KnowledgeSearchScope
    @Published private(set) var searching = false
    @Published private(set) var openingID: String?
    @Published private(set) var response: KnowledgeSearchResponse?
    @Published private(set) var error: String?
    @Published private(set) var destination: KnowledgeSearchDestination?
    private let service: KnowledgeSearchService
    private var operation: Task<Void, Never>?
    private var request = UUID()

    init(service: KnowledgeSearchService, scope: KnowledgeSearchScope = .all) { self.service = service; self.scope = scope }
    func clear() {
        request = UUID(); operation?.cancel(); operation = nil
        response = nil; error = nil; searching = false; openingID = nil; destination = nil
    }
    func search() {
        clear()
        let id = request
        let text = query
        let selectedScope = scope
        searching = true
        operation = Task(priority: .utility) { [service] in
            do {
                let response = try await service.search(text, scope: selectedScope)
                guard request == id, !Task.isCancelled else { return }
                self.response = response
            } catch is CancellationError {} catch {
                guard request == id else { return }
                self.error = error.localizedDescription
            }
            if request == id { searching = false; operation = nil }
        }
    }
    func open(_ hit: KnowledgeSearchHit) {
        guard openingID == nil, !searching else { return }
        let id = request
        openingID = hit.id; error = nil
        operation = Task(priority: .utility) { [service] in
            do {
                let target = try await service.open(hit)
                guard request == id, !Task.isCancelled else { return }
                destination = target
            } catch is CancellationError {} catch {
                guard request == id else { return }
                response = nil; self.error = error.localizedDescription
            }
            if request == id { openingID = nil; operation = nil }
        }
    }
    func back() { destination = nil }
    deinit { operation?.cancel() }
}

/// Человекочитаемая позиция фрагмента (панель памяти, источник, выдача).
/// Переехала из удалённого экрана поиска (#123); слой поиска остаётся
/// ядром инструмента агента.
nonisolated enum KnowledgeSearchLocation {
    static func label(_ chunk: KnowledgeChunk) -> String {
        if let page = chunk.location.page { return "Страница \(page) · Фрагмент \(chunk.ordinal + 1)" }
        if let start = chunk.location.startSeconds, let end = chunk.location.endSeconds {
            return "Реплика \(time(start))–\(time(end))"
        }
        if let paragraph = chunk.location.paragraph { return "Абзац \(paragraph) · Фрагмент \(chunk.ordinal + 1)" }
        return "Фрагмент \(chunk.ordinal + 1)"
    }
    private static func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 3_153_600_000 else { return "—" }
        let seconds = Int(value)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
