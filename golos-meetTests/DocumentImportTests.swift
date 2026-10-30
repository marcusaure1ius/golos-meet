import Foundation
import SQLite3
import Testing
@testable import golos_meet

private actor ImportGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor
@Suite struct DocumentImportTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func source(_ root: URL, name: String = "Решения.txt", text: String = "Решили запустить проект в ноябре.") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func importer(_ root: URL, store: ProjectStore) -> DocumentImporter {
        DocumentImporter(store: store, root: root.appendingPathComponent("knowledge"))
    }
    private func run(_ importer: DocumentImporter, _ url: URL, owners: Set<UUID> = [], target: UUID? = nil) async throws -> DocumentImportResult {
        try await importer.importFile(id: UUID(), url: url, projectIDs: owners, targetID: target) { _ in }
    }

    @Test func copiesDeduplicatesAcrossProjectsAndSurvivesLossOfExternalFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("knowledge.sqlite")
        let store = ProjectStore(url: dbURL)
        let a = try await store.createProject(name: "А")
        let b = try await store.createProject(name: "Б")
        let worker = importer(root, store: store)
        let file = try source(root)
        let original = try Data(contentsOf: file)
        let first = try await run(worker, file, owners: [a.id])
        let renamed = root.appendingPathComponent("Копия.md")
        try original.write(to: renamed)
        let repeated = try await run(worker, renamed, owners: [b.id])
        #expect(repeated.reused && repeated.documentID == first.documentID)
        #expect(try Data(contentsOf: file) == original)
        let documents = try await store.documents()
        let doc = try #require(documents.first)
        #expect(documents.count == 1)
        #expect(doc.title == "Решения")
        #expect(doc.versionCount == 1)
        #expect(doc.projectIDs == [a.id, b.id])
        #expect(try await store.chunks(for: doc.currentVersion.id).first?.text.contains("ноябре") == true)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: renamed)
        let saved = try await worker.fileURL(for: doc.currentVersion)
        #expect(try Data(contentsOf: saved) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? NSNumber)?.intValue == 0o444)
        #expect(try await ProjectStore(url: dbURL).documents() == documents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("knowledge/documents").path).count == 1)
    }

    @Test func importedTextPreservesEmbeddedNullAndUnicodeThroughSQLite() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let worker = importer(root, store: store)
        let text = "До\0после: русский текст и эмодзи 🚀"
        let file = try source(root, text: text)
        _ = try await run(worker, file)
        let document = try #require(try await store.documents().first)
        #expect(try await store.chunks(for: document.currentVersion.id).map(\.text).joined() == text)
    }

    @Test func explicitUpdateKeepsVersionsAndGenericImportNeverGuessesByName() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let worker = importer(root, store: store)
        let file = try source(root, text: "Старая версия: запуск в ноябре.")
        let first = try await run(worker, file)
        let old = try #require(try await store.documents().first)
        let previousBytes = try Data(contentsOf: await worker.fileURL(for: old.currentVersion))
        try Data("Новая версия: запуск в декабре.".utf8).write(to: file)
        let update = try await run(worker, file, target: first.documentID)
        #expect(!update.reused)
        let current = try #require(try await store.documents().first)
        #expect(current.versionCount == 2)
        #expect(current.currentVersion.id != old.currentVersion.id)
        #expect(try await store.chunks(for: current.currentVersion.id).first?.text.contains("декабре") == true)
        #expect(try await store.chunks(for: old.currentVersion.id).first?.text.contains("ноябре") == true)
        #expect(try Data(contentsOf: await worker.fileURL(for: old.currentVersion)) == previousBytes)
        try Data("Совсем другой документ с таким же именем.".utf8).write(to: file)
        let other = try await run(worker, file)
        #expect(other.documentID != first.documentID)
        #expect(try await store.documents().count == 2)
        try previousBytes.write(to: file)
        let oldCopy = try await run(worker, file)
        #expect(oldCopy.reused)
        #expect(try await store.documents().first { $0.id == first.documentID }?.currentVersion.id == current.currentVersion.id)
    }

    @Test func extractionAndCommitErrorsPreserveCurrentVersionAndOriginals() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let worker = importer(root, store: store)
        let file = try source(root)
        let initial = try await run(worker, file)
        let before = try await store.documents()
        try Data(" \n ".utf8).write(to: file)
        await #expect(throws: DocumentExtractionError.noText) { try await run(worker, file, target: initial.documentID) }
        #expect(try await store.documents() == before)
        let newFile = try source(root, name: "Другой.txt", text: "Извлечённый, но не сохранённый текст.")
        await #expect(throws: ProjectStoreError.missingProject) { try await run(worker, newFile, owners: [UUID()]) }
        #expect(try await store.documents() == before)
        #expect(try Data(contentsOf: newFile) == Data("Извлечённый, но не сохранённый текст.".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("knowledge/documents").path).count == 1)
        #expect(try await store.importAttempts().filter { $0.state == .failed }.count == 2)
    }

    @Test func cancellationDoesNotCancelFollowingQueuedFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let gate = ImportGate()
        let realExtractor = LocalDocumentExtractor()
        let worker = DocumentImporter(store: store, root: root.appendingPathComponent("knowledge"), extract: { url, progress in
            if try String(contentsOf: url, encoding: .utf8) == "Ожидание" { await gate.hold() }
            return try await realExtractor.extract(from: url, progress: progress)
        })
        let queue = DocumentImportQueue(importer: worker, store: store)
        let a = try source(root, name: "Отменить.txt", text: "Ожидание")
        let b = try source(root, name: "Продолжить.txt", text: "Следующий документ")
        let c = try source(root, name: "Пропустить.txt", text: "Не обрабатывать")
        await queue.enqueue(urls: [a, b, c], projectIDs: [])
        await gate.waitForStart()
        // The import's slow extraction does not occupy either the DB actor or a
        // separate meeting-processing queue. No real ASR or network is used.
        let project = try await store.createProject(name: "Пока идёт OCR")
        #expect(try await store.snapshot().projects.contains(project))
        let meetings = MeetingProcessor(processWork: { _, _ in }, insightsWork: { _, _ in })
        await meetings.enqueueAndWait(.process(deleteShortAudio: false), id: "synthetic", folder: root)
        #expect(meetings.completedJobsCount == 1)
        queue.cancel(try #require(queue.jobs.first?.id))
        queue.cancel(try #require(queue.jobs.last?.id))
        #expect(queue.jobs.first?.cancelRequested == true)
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(5)
        while queue.jobs.contains(where: { !$0.state.isTerminal }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(queue.jobs.map(\.state) == [.cancelled, .completed, .cancelled])
        #expect(try await store.documents().map(\.title) == ["Продолжить"])
        #expect(try await store.importAttempts().contains { $0.state == .cancelled })
        #expect(try String(contentsOf: a, encoding: .utf8) == "Ожидание")
    }

    @Test func failedChunkTransactionAndCancelledUpdateKeepPreviousVersion() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("knowledge.sqlite")
        let store = ProjectStore(url: dbURL)
        let worker = importer(root, store: store)
        let file = try source(root)
        let first = try await run(worker, file)
        let before = try await store.documents()
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TRIGGER test_failure BEFORE INSERT ON document_chunks WHEN NEW.text = 'fail transaction' BEGIN SELECT RAISE(ABORT, 'synthetic disk error'); END", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        try Data("fail transaction".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await run(worker, file, target: first.documentID) }
        #expect(try await store.documents() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("knowledge/documents").path).count == 1)
        let gate = ImportGate()
        let real = LocalDocumentExtractor()
        let cancellable = DocumentImporter(store: store, root: root.appendingPathComponent("knowledge"), extract: { url, progress in
            await gate.hold()
            return try await real.extract(from: url, progress: progress)
        })
        try Data("Новая версия для отмены".utf8).write(to: file)
        let task = Task { try await run(cancellable, file, target: first.documentID) }
        await gate.waitForStart()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.documents() == before)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Новая версия для отмены")
    }

    @Test func oversizedInputIsRejectedAndInterruptedAttemptsRecoverWithoutDataLoss() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        let store = ProjectStore(url: url)
        let worker = importer(root, store: store)
        let file = try source(root, name: "large.txt")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(LocalDocumentExtractor.maximumBytes + 1))
        try handle.close()
        await #expect(throws: DocumentExtractionError.fileTooLarge) { try await run(worker, file) }
        let attempt = UUID()
        try await store.startImport(id: attempt, filename: "pending.pdf", targetID: nil, state: .queued)
        let reopened = ProjectStore(url: url)
        try await reopened.recoverInterruptedImports()
        #expect(try await reopened.importAttempts().first { $0.id == attempt }?.state == .interrupted)
        #expect(try await reopened.documents().isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int == LocalDocumentExtractor.maximumBytes + 1)
    }

    @Test func migrationFromV1KeepsProjectsAndFailedMigrationRollsBack() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        let id = UUID()
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE projects(id TEXT PRIMARY KEY, name TEXT, parent_id TEXT, cloud_policy TEXT); CREATE TABLE meeting_decisions(meeting_id TEXT PRIMARY KEY, origin TEXT); CREATE TABLE meeting_projects(meeting_id TEXT, project_id TEXT); INSERT INTO projects VALUES ('\(id.uuidString)', 'Существующий', NULL, 'localOnly'); INSERT INTO meeting_decisions VALUES ('M','manual'); INSERT INTO meeting_projects VALUES ('M','\(id.uuidString)'); PRAGMA user_version=1", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let migrated = ProjectStore(url: url)
        #expect(try await migrated.snapshot().meetingProjects["M"] == [id])
        #expect(try await migrated.documents().isEmpty)
        let failedURL = root.appendingPathComponent("failed.sqlite")
        #expect(sqlite3_open(failedURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE documents(keep TEXT); INSERT INTO documents VALUES ('original'); PRAGMA user_version=1", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: failedURL)
        await #expect(throws: (any Error).self) { try await ProjectStore(url: failedURL).documents() }
        #expect(try Data(contentsOf: failedURL) == before)
    }
}
