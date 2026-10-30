import Foundation
import Testing
@testable import golos_meet

@MainActor
@Suite struct DocumentImportRetryTests {
    @Test(arguments: [DocumentImportState.extracting, .failed])
    func retryAfterRestartPreservesUpdateTarget(state: DocumentImportState) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-update-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("knowledge.sqlite")
        let copies = root.appendingPathComponent("knowledge")
        let source = root.appendingPathComponent("Требования.txt")
        let store = ProjectStore(url: dbURL)
        let project = try await store.createProject(name: "Проект")
        let importer = DocumentImporter(store: store, root: copies)
        try Data("Первая версия требований".utf8).write(to: source)
        let first = try await importer.importFile(id: UUID(), url: source, projectIDs: [project.id]) { _ in }
        let previous = try #require(try await store.documents().first)
        let attemptID = UUID()
        try await store.startImport(id: attemptID, filename: source.lastPathComponent, targetID: first.documentID, state: state)
        // A fresh UI model performs startup recovery and uses the same operation
        // as the history row after the user selects the replacement file.
        let restarted = DocumentLibrary(store: ProjectStore(url: dbURL), root: copies)
        await restarted.reload()
        let attempt = try #require(restarted.attempts.first { $0.id == attemptID })
        #expect(attempt.targetID == first.documentID)
        #expect(attempt.state == (state == .failed ? .failed : .interrupted))
        let replacement = root.appendingPathComponent("Новое имя.txt")
        try Data("Вторая версия: новые требования".utf8).write(to: replacement)
        await restarted.retryImport(attempt, selecting: replacement)
        let deadline = ContinuousClock.now + .seconds(5)
        while restarted.queue.jobs.contains(where: { !$0.state.isTerminal }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(restarted.queue.jobs.first?.targetID == first.documentID)
        #expect(restarted.queue.jobs.first?.state == .completed)
        await restarted.reload()
        #expect(restarted.documents.count == 1)
        let updated = try #require(restarted.documents.first)
        #expect(updated.id == first.documentID)
        #expect(updated.projectIDs == [project.id])
        #expect(updated.versionCount == 2)
        #expect(updated.currentVersion.id != previous.currentVersion.id)
        #expect(try await restarted.store.chunks(for: updated.currentVersion.id).first?.text == "Вторая версия: новые требования")
        #expect(try await restarted.store.chunks(for: previous.currentVersion.id).first?.text == "Первая версия требований")
        #expect(try Data(contentsOf: await restarted.importer.fileURL(for: previous.currentVersion)) == Data("Первая версия требований".utf8))
    }

    @Test func missingUpdateTargetIsNeverRetriedAsNewDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-missing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = DocumentLibrary(store: ProjectStore(url: root.appendingPathComponent("knowledge.sqlite")), root: root.appendingPathComponent("knowledge"))
        await library.reload()
        let file = root.appendingPathComponent("Замена.txt")
        try Data("Этот текст не должен стать новым документом".utf8).write(to: file)
        let missingID = UUID()
        let attempt = DocumentImportAttempt(id: UUID(), filename: "Старое имя.txt", targetID: missingID,
            state: .interrupted, message: "Прервано", createdAt: Date())
        await library.retryImport(attempt, selecting: file)
        #expect(library.queue.jobs.first?.targetID == missingID)
        #expect(library.queue.jobs.first?.state == .failed)
        #expect(try await library.store.documents().isEmpty)
        #expect(try Data(contentsOf: file) == Data("Этот текст не должен стать новым документом".utf8))
    }
}
