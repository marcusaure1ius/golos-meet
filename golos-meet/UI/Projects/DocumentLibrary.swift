import Foundation
import Combine

@MainActor
final class DocumentLibrary: ObservableObject {
    static let shared = DocumentLibrary(store: ProjectLibrary.shared.store,
        root: AppPaths.appSupport.appendingPathComponent("knowledge", isDirectory: true))
    @Published private(set) var documents: [LibraryDocument] = []
    @Published private(set) var attempts: [DocumentImportAttempt] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoaded = false
    @Published private(set) var error: String?
    let queue: DocumentImportQueue
    let importer: DocumentImporter
    let store: ProjectStore
    private var recovered = false
    private var reloadRequested = false

    init(store: ProjectStore, root: URL, extract: DocumentExtractionWork? = nil) {
        self.store = store
        let importer = DocumentImporter(store: store, root: root, extract: extract)
        self.importer = importer
        queue = DocumentImportQueue(importer: importer, store: store)
    }

    func reload() async {
        if isLoading { reloadRequested = true; return }
        isLoading = true
        defer { isLoading = false }
        repeat {
            reloadRequested = false
            do {
                if !recovered {
                    try await store.recoverInterruptedImports()
                    recovered = true
                }
                documents = try await store.documents()
                attempts = try await store.importAttempts()
                isLoaded = true
                error = nil
            } catch { self.error = error.localizedDescription }
        } while reloadRequested
    }

    func documents(in scope: ProjectMeetingScope) -> [LibraryDocument] {
        documents.filter { document in
            switch scope {
            case .all: return true
            case .inbox: return document.projectIDs.isEmpty
            case .project(let id): return document.projectIDs.contains(id)
            }
        }
    }

    /// A persisted update must keep its source identity after restart. Never
    /// replace a missing target with nil: the store will reject that update.
    func retryImport(_ attempt: DocumentImportAttempt, selecting url: URL) async {
        await queue.enqueue(urls: [url], projectIDs: [], targetID: attempt.targetID)
    }
}
