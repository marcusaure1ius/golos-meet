import Foundation
import SQLite3

nonisolated enum ProjectStoreError: LocalizedError, Equatable {
    case database(String)
    case newerSchema(Int)
    case invalidName
    case missingProject
    case invalidMeetingID

    var errorDescription: String? {
        switch self {
        case .database: return "Не удалось открыть или сохранить библиотеку проектов. Проверьте доступ к диску и повторите попытку."
        case .newerSchema: return "Библиотека создана более новой версией Golos Meet. Обновите приложение."
        case .invalidName: return "Введите название проекта от 1 до 200 символов."
        case .missingProject: return "Проект больше не существует. Обновите библиотеку и выберите проект снова."
        case .invalidMeetingID: return "Не удалось определить встречу для назначения."
        }
    }
}

nonisolated struct ProjectSnapshot: Sendable, Equatable {
    var projects: [KnowledgeProject] = []
    var meetingProjects: [String: Set<UUID>] = [:]
}

/// SQLite is used only from ProjectStore's executor. No meeting file is opened here.
/// The wrapper is Sendable solely to allow deterministic close in deinit.
private nonisolated final class ProjectDatabase: @unchecked Sendable {
    let handle: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open"
            if let db { sqlite3_close(db) }
            throw ProjectStoreError.database(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, bindings: [String] = [], blob: Data? = nil) throws {
        let statement = try prepare(sql, bindings: bindings, blob: blob)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func rows(_ sql: String, bindings: [String] = []) throws -> [[String]] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    guard let bytes = sqlite3_column_text(statement, column) else { return "" }
                    let count = Int(sqlite3_column_bytes(statement, column))
                    return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
                })
            case SQLITE_DONE: return rows
            default: throw failure()
            }
        }
    }

    /// Binary selects put the BLOB last; text decoding never touches vector bytes.
    func binaryRows(_ sql: String, bindings: [String]) throws -> [(fields: [String], data: Data)] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [(fields: [String], data: Data)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let last = sqlite3_column_count(statement) - 1
                guard last >= 0, sqlite3_column_type(statement, last) == SQLITE_BLOB,
                      let bytes = sqlite3_column_blob(statement, last) else { throw EmbeddingIndexError.corruptIndex }
                let fields = (0..<last).map { column -> String in
                    guard let text = sqlite3_column_text(statement, column) else { return "" }
                    return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
                }
                result.append((fields, Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, last)))))
            case SQLITE_DONE: return result
            default: throw failure()
            }
        }
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, bindings: [String], blob: Data? = nil) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        for (index, value) in bindings.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw failure()
            }
        }
        if let blob {
            let result = blob.withUnsafeBytes {
                sqlite3_bind_blob(statement, Int32(bindings.count + 1), $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }

    private func failure() -> ProjectStoreError {
        .database(String(cString: sqlite3_errmsg(handle)))
    }
}

actor ProjectStore {
    private let url: URL
    private var database: ProjectDatabase?

    init(url: URL) { self.url = url }

    func snapshot() throws -> ProjectSnapshot {
        let db = try open()
        return try db.transaction {
            var result = ProjectSnapshot()
            for row in try db.rows("SELECT id, name, parent_id, cloud_policy FROM projects ORDER BY name COLLATE NOCASE, id") {
                guard let id = UUID(uuidString: row[0]), let policy = ProjectCloudPolicy(rawValue: row[3]) else {
                    throw ProjectStoreError.database("Invalid project record")
                }
                result.projects.append(KnowledgeProject(id: id, name: row[1], parentID: UUID(uuidString: row[2]), cloudPolicy: policy))
            }
            for row in try db.rows("SELECT meeting_id, project_id FROM meeting_projects") {
                guard let projectID = UUID(uuidString: row[1]) else { throw ProjectStoreError.database("Invalid assignment") }
                result.meetingProjects[row[0], default: []].insert(projectID)
            }
            return result
        }
    }

    func createProject(name: String, parentID: UUID? = nil) throws -> KnowledgeProject {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, !name.contains("\0") else { throw ProjectStoreError.invalidName }
        let db = try open()
        let project = KnowledgeProject(name: name, parentID: parentID)
        try db.transaction {
            if let parentID { try requireProject(parentID, db: db) }
            // NULLIF preserves a real SQL NULL for a root project.
            try db.execute("INSERT INTO projects (id, name, parent_id, cloud_policy) VALUES (?, ?, NULLIF(?, ''), ?)",
                           bindings: [project.id.uuidString, name, parentID?.uuidString ?? "", project.cloudPolicy.rawValue])
        }
        return project
    }

    /// An empty set explicitly returns the meeting to Inbox. The manual decision
    /// remains recorded so a later automatic classifier cannot overwrite it.
    func assignMeeting(_ meetingID: String, to projectIDs: Set<UUID>) throws {
        guard !meetingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !meetingID.contains("\0") else {
            throw ProjectStoreError.invalidMeetingID
        }
        let db = try open()
        try db.transaction {
            for id in projectIDs { try requireProject(id, db: db) }
            try db.execute("INSERT INTO meeting_decisions (meeting_id, origin) VALUES (?, 'manual') ON CONFLICT(meeting_id) DO UPDATE SET origin = 'manual'",
                           bindings: [meetingID])
            try db.execute("DELETE FROM meeting_projects WHERE meeting_id = ?", bindings: [meetingID])
            for id in projectIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                try db.execute("INSERT INTO meeting_projects (meeting_id, project_id) VALUES (?, ?)", bindings: [meetingID, id.uuidString])
            }
        }
    }

    private func requireProject(_ id: UUID, db: ProjectDatabase) throws {
        guard try !db.rows("SELECT id FROM projects WHERE id = ?", bindings: [id.uuidString]).isEmpty else {
            throw ProjectStoreError.missingProject
        }
    }

    private func open() throws -> ProjectDatabase {
        if let database { return database }
        let db = try ProjectDatabase(url: url)
        try db.execute("PRAGMA foreign_keys = ON")
        let version = Int(try db.rows("PRAGMA user_version").first?.first ?? "") ?? -1
        guard version <= 3 else { throw ProjectStoreError.newerSchema(version) }
        guard version >= 0 else { throw ProjectStoreError.database("Invalid schema version") }
        if version == 0 {
            try db.transaction {
                try db.execute("CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 200), parent_id TEXT REFERENCES projects(id), cloud_policy TEXT NOT NULL DEFAULT 'localOnly')")
                try db.execute("CREATE TABLE meeting_decisions (meeting_id TEXT PRIMARY KEY NOT NULL, origin TEXT NOT NULL CHECK(origin = 'manual'))")
                try db.execute("CREATE TABLE meeting_projects (meeting_id TEXT NOT NULL REFERENCES meeting_decisions(meeting_id), project_id TEXT NOT NULL REFERENCES projects(id), PRIMARY KEY (meeting_id, project_id))")
                try db.execute("CREATE INDEX meeting_projects_by_project ON meeting_projects(project_id)")
                try db.execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try db.transaction {
                try db.execute("CREATE TABLE documents (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, current_version TEXT)")
                try db.execute("CREATE TABLE document_versions (id TEXT PRIMARY KEY NOT NULL, document_id TEXT NOT NULL REFERENCES documents(id), content_hash TEXT NOT NULL, relative_path TEXT NOT NULL UNIQUE, original_name TEXT NOT NULL, imported_at TEXT NOT NULL, warnings TEXT NOT NULL, UNIQUE(document_id, content_hash))")
                try db.execute("CREATE INDEX document_versions_by_hash ON document_versions(content_hash)")
                try db.execute("CREATE TABLE document_projects (document_id TEXT NOT NULL REFERENCES documents(id), project_id TEXT NOT NULL REFERENCES projects(id), PRIMARY KEY(document_id, project_id))")
                try db.execute("CREATE TABLE document_chunks (id TEXT PRIMARY KEY NOT NULL, version_id TEXT NOT NULL REFERENCES document_versions(id), ordinal TEXT NOT NULL, text TEXT NOT NULL, location TEXT NOT NULL)")
                try db.execute("CREATE TABLE document_imports (id TEXT PRIMARY KEY NOT NULL, filename TEXT NOT NULL, target_id TEXT, state TEXT NOT NULL, message TEXT NOT NULL, created_at TEXT NOT NULL)")
                try db.execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try db.transaction {
                try db.execute("CREATE TABLE embedding_models (model_id TEXT PRIMARY KEY NOT NULL, dimensions INTEGER NOT NULL CHECK(dimensions BETWEEN 1 AND 4096))")
                try db.execute("CREATE TABLE embedding_active_model (slot INTEGER PRIMARY KEY CHECK(slot = 1), model_id TEXT NOT NULL REFERENCES embedding_models(model_id), dimensions INTEGER NOT NULL CHECK(dimensions BETWEEN 1 AND 4096))")
                try db.execute("CREATE TABLE embedding_sources (source_key TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('document','meeting')), external_id TEXT NOT NULL, revision TEXT NOT NULL, UNIQUE(kind, external_id))")
                try db.execute("CREATE TABLE embedding_chunks (id TEXT PRIMARY KEY NOT NULL, source_key TEXT NOT NULL REFERENCES embedding_sources(source_key) ON DELETE CASCADE, source_id TEXT NOT NULL, revision TEXT NOT NULL, ordinal INTEGER NOT NULL, text TEXT NOT NULL, location TEXT NOT NULL, body_tokens INTEGER NOT NULL DEFAULT 0 CHECK(body_tokens >= 0), UNIQUE(source_key, ordinal))")
                try db.execute("CREATE TABLE embedding_jobs (source_key TEXT PRIMARY KEY NOT NULL REFERENCES embedding_sources(source_key) ON DELETE CASCADE, generation TEXT NOT NULL, model_id TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('waitingForModel','queued','running','ready','failed','cancelled')), completed INTEGER NOT NULL, total INTEGER NOT NULL, message TEXT NOT NULL, attempt TEXT NOT NULL DEFAULT '')")
                try db.execute("CREATE INDEX embedding_jobs_by_state ON embedding_jobs(state, source_key)")
                try db.execute("CREATE TABLE embedding_vectors (chunk_id TEXT NOT NULL REFERENCES embedding_chunks(id) ON DELETE CASCADE, model_id TEXT NOT NULL, token_start INTEGER NOT NULL CHECK(token_start >= 0), token_count INTEGER NOT NULL CHECK(token_count > 0), dimensions INTEGER NOT NULL CHECK(dimensions BETWEEN 1 AND 4096), vector BLOB NOT NULL CHECK(length(vector) = dimensions * 4), PRIMARY KEY(chunk_id, model_id, token_start))")
                try db.execute("PRAGMA user_version = 3")
            }
        }
        database = db
        return db
    }
}

extension ProjectStore {
    func documents() throws -> [LibraryDocument] {
        let db = try open()
        return try db.transaction {
            try db.rows("SELECT id, title, current_version FROM documents WHERE current_version IS NOT NULL ORDER BY title COLLATE NOCASE, id").map { row in
                guard let id = UUID(uuidString: row[0]), let versionID = UUID(uuidString: row[2]),
                      let version = try readVersions(id, db: db).first(where: { $0.id == versionID }) else {
                    throw DocumentImportError.invalidRecord
                }
                let owners = try db.rows("SELECT project_id FROM document_projects WHERE document_id = ?", bindings: [id.uuidString]).map { row in
                    guard let id = UUID(uuidString: row[0]) else { throw DocumentImportError.invalidRecord }
                    return id
                }
                let count = Int(try db.rows("SELECT COUNT(*) FROM document_versions WHERE document_id = ?", bindings: [id.uuidString])[0][0]) ?? 0
                return LibraryDocument(id: id, title: row[1], currentVersion: version, versionCount: count, projectIDs: Set(owners))
            }
        }
    }

    func versions(for documentID: UUID) throws -> [DocumentVersion] {
        try readVersions(documentID, db: open())
    }

    func chunks(for versionID: UUID) throws -> [KnowledgeChunk] {
        let db = try open()
        let versions = try db.rows("SELECT document_id, content_hash FROM document_versions WHERE id = ?", bindings: [versionID.uuidString])
        guard let version = versions.first, let sourceID = UUID(uuidString: version[0]) else { throw DocumentImportError.missingDocument }
        return try db.rows("SELECT id, ordinal, text, location FROM document_chunks WHERE version_id = ? ORDER BY CAST(ordinal AS INTEGER)", bindings: [versionID.uuidString]).map { row in
            guard let ordinal = Int(row[1]), let data = row[3].data(using: .utf8) else { throw DocumentImportError.invalidRecord }
            return KnowledgeChunk(id: row[0], sourceID: sourceID, revision: version[1], ordinal: ordinal, text: row[2], location: try JSONDecoder().decode(KnowledgeLocation.self, from: data))
        }
    }

    func startImport(id: UUID, filename: String, targetID: UUID?, state: DocumentImportState = .copying) throws {
        try Task.checkCancellation()
        let db = try open()
        if let targetID { try requireDocument(targetID, db: db) }
        try db.execute("INSERT INTO document_imports VALUES (?, ?, NULLIF(?, ''), ?, '', ?) ON CONFLICT(id) DO UPDATE SET state = excluded.state, message = ''", bindings: [id.uuidString, filename, targetID?.uuidString ?? "", state.rawValue, String(Date().timeIntervalSince1970)])
    }

    func updateImport(id: UUID, state: DocumentImportState, message: String = "") throws {
        try open().execute("UPDATE document_imports SET state = ?, message = ? WHERE id = ?", bindings: [state.rawValue, message, id.uuidString])
    }

    func recoverInterruptedImports() throws {
        try open().execute("UPDATE document_imports SET state = 'interrupted', message = 'Импорт был прерван. Выберите файл и импортируйте его снова.' WHERE state IN ('queued','copying','extracting','indexing','saving')")
    }

    func importAttempts() throws -> [DocumentImportAttempt] {
        try open().rows("SELECT id, filename, target_id, state, message, created_at FROM document_imports ORDER BY CAST(created_at AS REAL) DESC LIMIT 30").map { row in
            guard let id = UUID(uuidString: row[0]), let state = DocumentImportState(rawValue: row[3]), let time = Double(row[5]) else { throw DocumentImportError.invalidRecord }
            return DocumentImportAttempt(id: id, filename: row[1], targetID: UUID(uuidString: row[2]), state: state, message: row[4], createdAt: Date(timeIntervalSince1970: time))
        }
    }

    /// Check by bytes, never by filename. Historical bytes identify an existing
    /// document too; importing an old copy does not roll back its current version.
    func matchingDocument(contentHash: String) throws -> UUID? {
        let rows = try open().rows("SELECT document_id FROM document_versions WHERE content_hash = ? ORDER BY imported_at DESC, id LIMIT 1", bindings: [contentHash])
        return rows.first.flatMap { UUID(uuidString: $0[0]) }
    }

    /// Called only after an immutable file has been installed. A cancellation or
    /// database error before COMMIT rolls back metadata, chunks and the current pointer.
    func commitImport(attemptID: UUID, documentID: UUID, targetID: UUID?, projectIDs: Set<UUID>,
                      extracted: ExtractedDocument, version: DocumentVersion, chunks: [KnowledgeChunk]) throws -> DocumentImportResult {
        try Task.checkCancellation()
        let db = try open()
        return try db.transaction {
            for id in projectIDs { try requireProject(id, db: db) }
            let existingID: UUID?
            if let targetID { try requireDocument(targetID, db: db); existingID = targetID }
            else {
                existingID = try db.rows("SELECT document_id FROM document_versions WHERE content_hash = ? ORDER BY imported_at DESC, id LIMIT 1", bindings: [extracted.contentHash]).first.flatMap { UUID(uuidString: $0[0]) }
            }
            let id = existingID ?? documentID
            let knownVersion = try db.rows("SELECT id FROM document_versions WHERE document_id = ? AND content_hash = ?", bindings: [id.uuidString, extracted.contentHash]).first
            if existingID == nil {
                try db.execute("INSERT INTO documents (id, title) VALUES (?, ?)", bindings: [id.uuidString, extracted.title])
            }
            for projectID in projectIDs {
                try db.execute("INSERT OR IGNORE INTO document_projects VALUES (?, ?)", bindings: [id.uuidString, projectID.uuidString])
            }
            if knownVersion == nil {
                guard id == documentID, version.documentID == id else { throw DocumentImportError.invalidRecord }
                let warnings = String(decoding: try JSONEncoder().encode(extracted.warnings), as: UTF8.self)
                try db.execute("INSERT INTO document_versions VALUES (?, ?, ?, ?, ?, ?, ?)", bindings: [version.id.uuidString, id.uuidString, extracted.contentHash, version.relativePath, version.originalName, String(version.importedAt.timeIntervalSince1970), warnings])
                for chunk in chunks {
                    try Task.checkCancellation()
                    let location = String(decoding: try JSONEncoder().encode(chunk.location), as: UTF8.self)
                    try db.execute("INSERT INTO document_chunks VALUES (?, ?, ?, ?, ?)", bindings: [chunk.id, version.id.uuidString, String(chunk.ordinal), chunk.text, location])
                }
                try db.execute("UPDATE documents SET current_version = ? WHERE id = ?", bindings: [version.id.uuidString, id.uuidString])
            }
            // An explicit update to already-known bytes selects that saved version.
            if targetID != nil, let knownVersion {
                try db.execute("UPDATE documents SET current_version = ? WHERE id = ?", bindings: [knownVersion[0], id.uuidString])
            }
            // The source pointer, job generation and invalidation of old vectors
            // belong to the same transaction as the document version switch.
            try synchronizeDocumentEmbedding(id, db: db)
            try Task.checkCancellation()
            let reused = knownVersion != nil
            try db.execute("UPDATE document_imports SET state = 'completed', message = ? WHERE id = ?", bindings: [reused ? "Документ уже в библиотеке; копия не добавлена." : "Документ и фрагменты сохранены локально.", attemptID.uuidString])
            return DocumentImportResult(documentID: id, reused: reused)
        }
    }

    private func requireDocument(_ id: UUID, db: ProjectDatabase) throws {
        guard try !db.rows("SELECT id FROM documents WHERE id = ?", bindings: [id.uuidString]).isEmpty else { throw DocumentImportError.missingDocument }
    }

    private func readVersions(_ documentID: UUID, db: ProjectDatabase) throws -> [DocumentVersion] {
        try db.rows("SELECT v.id, v.content_hash, v.relative_path, v.original_name, v.imported_at, v.warnings, (SELECT COUNT(*) FROM document_chunks c WHERE c.version_id = v.id) FROM document_versions v WHERE document_id = ? ORDER BY CAST(imported_at AS REAL) DESC, id", bindings: [documentID.uuidString]).map { row in
            guard let id = UUID(uuidString: row[0]), let time = Double(row[4]), let count = Int(row[6]), let data = row[5].data(using: .utf8) else { throw DocumentImportError.invalidRecord }
            return DocumentVersion(id: id, documentID: documentID, contentHash: row[1], relativePath: row[2], originalName: row[3], importedAt: Date(timeIntervalSince1970: time), warnings: try JSONDecoder().decode([String].self, from: data), chunkCount: count)
        }
    }
}

// MARK: - Durable embedding catalog and transactional publication

extension ProjectStore {
    func embeddingRevision(for key: EmbeddingSourceKey) throws -> String? {
        try open().rows("SELECT revision FROM embedding_sources WHERE source_key = ?", bindings: [key.rawValue]).first?.first
    }

    /// Seed documents imported before schema v3. Ordinary imports update this
    /// catalog in their own commit, including explicit selection of an old version.
    func synchronizeEmbeddingDocuments() throws {
        let db = try open()
        try db.transaction {
            for row in try db.rows("SELECT id FROM documents WHERE current_version IS NOT NULL") {
                guard let id = UUID(uuidString: row[0]) else { throw EmbeddingIndexError.invalidSource }
                try synchronizeDocumentEmbedding(id, db: db)
            }
        }
    }

    @discardableResult
    func synchronizeMeetingEmbedding(_ snapshot: EmbeddingSourceSnapshot, replacing expectedRevision: String?) throws -> Bool {
        guard snapshot.key.kind == .meeting else { throw EmbeddingIndexError.invalidSource }
        let db = try open()
        return try db.transaction {
            let current = try db.rows("SELECT revision FROM embedding_sources WHERE source_key = ?", bindings: [snapshot.key.rawValue]).first?.first
            guard current == expectedRevision else { return false }
            try registerEmbeddingSource(snapshot, db: db)
            return true
        }
    }

    /// Call after a source is deleted or a meeting transcript is found invalid.
    /// Cascades invalidate outstanding leases and remove its derived data only.
    func removeEmbeddingSource(_ key: EmbeddingSourceKey) throws {
        try open().execute("DELETE FROM embedding_sources WHERE source_key = ?", bindings: [key.rawValue])
    }

    @discardableResult
    func invalidateMeetingEmbedding(_ key: EmbeddingSourceKey, replacing expectedRevision: String?) throws -> Bool {
        guard key.kind == .meeting else { throw EmbeddingIndexError.invalidSource }
        let db = try open()
        return try db.transaction {
            let current = try db.rows("SELECT revision FROM embedding_sources WHERE source_key = ?", bindings: [key.rawValue]).first?.first
            guard current == expectedRevision else { return false }
            try db.execute("DELETE FROM embedding_sources WHERE source_key = ?", bindings: [key.rawValue])
            return true
        }
    }

    func activateEmbeddingModel(_ model: EmbeddingIndexModel) throws {
        guard !model.id.isEmpty, !model.id.contains("\0"), model.id.utf8.count <= 512,
              (1...4096).contains(model.dimensions) else { throw EmbeddingIndexError.invalidModel }
        let db = try open()
        try db.transaction {
            if let known = try db.rows("SELECT dimensions FROM embedding_models WHERE model_id = ?", bindings: [model.id]).first {
                guard Int(known[0]) == model.dimensions else { throw EmbeddingIndexError.invalidModel }
            } else {
                try db.execute("INSERT INTO embedding_models VALUES (?, ?)", bindings: [model.id, String(model.dimensions)])
            }
            guard try embeddingModel(db) != model else { return }
            try db.execute("INSERT INTO embedding_active_model VALUES (1, ?, ?) ON CONFLICT(slot) DO UPDATE SET model_id = excluded.model_id, dimensions = excluded.dimensions",
                           bindings: [model.id, String(model.dimensions)])
            try db.execute("DELETE FROM embedding_vectors")
            for row in try db.rows("SELECT source_key FROM embedding_sources") { try resetEmbeddingJob(row[0], db: db) }
        }
    }

    func embeddingJobs() throws -> [EmbeddingIndexJob] {
        try readEmbeddingJobs(open())
    }

    /// A lease is exclusive even when multiple queue instances share a database.
    /// Its generation also protects A→B→A source/model changes and cancellation.
    func claimEmbeddingJob() throws -> EmbeddingIndexLease? {
        let db = try open()
        return try db.transaction {
            guard let model = try embeddingModel(db),
                  let job = try readEmbeddingJobs(db, queuedFor: model.id).first else { return nil }
            let snapshot = try embeddingSnapshot(job.source, db: db)
            let attempt = UUID().uuidString
            try db.execute("UPDATE embedding_jobs SET state = 'running', attempt = ?, completed = 0 WHERE source_key = ?",
                           bindings: [attempt, job.source.rawValue])
            return .init(job: job, attempt: attempt, model: model, snapshot: snapshot)
        }
    }

    @discardableResult
    func updateEmbeddingProgress(_ lease: EmbeddingIndexLease, completed: Int) throws -> Bool {
        let db = try open()
        return try db.transaction {
            guard try embeddingLeaseIsCurrent(lease, db: db) else { return false }
            guard (0...lease.job.total).contains(completed) else { throw EmbeddingIndexError.invalidVectors }
            try db.execute("UPDATE embedding_jobs SET completed = MAX(completed, CAST(? AS INTEGER)) WHERE source_key = ?",
                           bindings: [String(completed), lease.job.source.rawValue])
            return true
        }
    }

    @discardableResult
    func failEmbeddingJob(_ lease: EmbeddingIndexLease) throws -> Bool {
        let db = try open()
        return try db.transaction {
            guard try embeddingLeaseIsCurrent(lease, db: db) else { return false }
            try db.execute("UPDATE embedding_jobs SET state = 'failed', attempt = '', message = 'Не удалось вычислить индекс. Повторите индексацию.' WHERE source_key = ?",
                           bindings: [lease.job.source.rawValue])
            return true
        }
    }

    func cancelEmbeddingJob(_ key: EmbeddingSourceKey) throws {
        let db = try open()
        try db.execute("UPDATE embedding_jobs SET state = 'cancelled', generation = ?, attempt = '', message = 'Индексирование отменено.' WHERE source_key = ? AND state != 'ready'",
                       bindings: [UUID().uuidString, key.rawValue])
    }

    func retryEmbeddingJob(_ key: EmbeddingSourceKey) throws {
        let db = try open()
        try db.transaction {
            guard try readEmbeddingJobs(db, sourceKey: key.rawValue).contains(where: { [.failed, .cancelled].contains($0.state) }) else { return }
            try resetEmbeddingJob(key.rawValue, db: db)
        }
    }

    func requestEmbeddingReindex(_ key: EmbeddingSourceKey) throws {
        let db = try open()
        try db.transaction {
            guard try !db.rows("SELECT source_key FROM embedding_sources WHERE source_key = ?", bindings: [key.rawValue]).isEmpty else {
                throw EmbeddingIndexError.invalidSource
            }
            try resetEmbeddingJob(key.rawValue, db: db)
        }
    }

    /// Explicit startup recovery. Do not call while a live queue owns leases.
    func recoverEmbeddingJobs() throws {
        let db = try open()
        try db.transaction {
            for row in try db.rows("SELECT source_key FROM embedding_jobs WHERE state = 'running'") {
                try resetEmbeddingJob(row[0], db: db)
            }
        }
    }

    /// All chunks and windows publish atomically, never one partial chunk at a
    /// time. No old-generation progress/failure/result may mutate a newer job.
    @discardableResult
    func publishEmbeddingVectors(_ results: [IndexedChunkVectors], lease: EmbeddingIndexLease) throws -> Bool {
        try Task.checkCancellation()
        let db = try open()
        return try db.transaction {
            guard try embeddingLeaseIsCurrent(lease, db: db) else { return false }
            let chunkIDs = Set(lease.snapshot.chunks.map(\.id))
            guard results.count == chunkIDs.count, Set(results.map(\.chunkID)) == chunkIDs else { throw EmbeddingIndexError.invalidVectors }
            try db.execute("DELETE FROM embedding_vectors WHERE chunk_id IN (SELECT id FROM embedding_chunks WHERE source_key = ?)", bindings: [lease.job.source.rawValue])
            for result in results {
                guard result.bodyTokenCount > 0, !result.windows.isEmpty else { throw EmbeddingIndexError.invalidVectors }
                try db.execute("UPDATE embedding_chunks SET body_tokens = ? WHERE id = ?", bindings: [String(result.bodyTokenCount), result.chunkID])
                var previousStart = -1, covered = 0
                for window in result.windows {
                    try Task.checkCancellation()
                    guard window.tokenStart >= 0, window.tokenCount > 0,
                          window.tokenStart <= Int.max - window.tokenCount,
                          window.tokenStart > previousStart, window.tokenStart <= covered,
                          window.tokenStart + window.tokenCount > covered,
                          window.vector.modelID == lease.model.id, window.vector.values.count == lease.model.dimensions else {
                        throw EmbeddingIndexError.invalidVectors
                    }
                    previousStart = window.tokenStart
                    covered = window.tokenStart + window.tokenCount
                    try db.execute("INSERT INTO embedding_vectors VALUES (?, ?, ?, ?, ?, ?)",
                                   bindings: [result.chunkID, lease.model.id, String(window.tokenStart), String(window.tokenCount), String(lease.model.dimensions)],
                                   blob: EmbeddingVectorBytes.encode(window.vector))
                }
                guard covered == result.bodyTokenCount else { throw EmbeddingIndexError.invalidVectors }
            }
            try Task.checkCancellation()
            try db.execute("UPDATE embedding_jobs SET state = 'ready', completed = total, attempt = '', message = '' WHERE source_key = ?", bindings: [lease.job.source.rawValue])
            return true
        }
    }

    /// Reads only a completely published index for the active model/current
    /// source revision. Query scoring and project filtering belong to #14.
    func embeddingWindows(for key: EmbeddingSourceKey, model: EmbeddingIndexModel) throws -> [StoredEmbeddingWindow] {
        let db = try open()
        return try db.transaction {
            guard try embeddingModel(db) == model else { throw EmbeddingIndexError.invalidModel }
            guard let job = try readEmbeddingJobs(db, sourceKey: key.rawValue).first, job.state == .ready else { return [] }
            guard job.modelID == model.id else { throw EmbeddingIndexError.corruptIndex }
            let snapshot = try embeddingSnapshot(key, db: db)
            guard try embeddingDocumentIsCurrent(snapshot, db: db) else { return [] }
            guard job.total > 0, job.completed == job.total, snapshot.chunks.count == job.total else { throw EmbeddingIndexError.corruptIndex }
            let chunks = Dictionary(uniqueKeysWithValues: snapshot.chunks.map { ($0.id, $0) })
            let rows = try db.binaryRows("SELECT v.chunk_id, v.token_start, v.token_count, v.dimensions, c.body_tokens, v.vector FROM embedding_vectors v JOIN embedding_chunks c ON c.id = v.chunk_id WHERE c.source_key = ? AND v.model_id = ? ORDER BY c.ordinal, v.token_start", bindings: [key.rawValue, model.id])
            var coverage: [String: (start: Int, end: Int, total: Int)] = [:]
            let result: [StoredEmbeddingWindow] = try rows.map { row in
                guard let chunk = chunks[row.fields[0]], let start = Int(row.fields[1]), let count = Int(row.fields[2]),
                      Int(row.fields[3]) == model.dimensions, let total = Int(row.fields[4]), total > 0,
                      start >= 0, count > 0, start <= Int.max - count else { throw EmbeddingIndexError.corruptIndex }
                let previous = coverage[chunk.id] ?? (start: -1, end: 0, total: total)
                guard start > previous.start, start <= previous.end, start + count > previous.end,
                      total == previous.total else { throw EmbeddingIndexError.corruptIndex }
                coverage[chunk.id] = (start, start + count, total)
                return .init(source: key, revision: snapshot.revision, chunk: chunk, tokenStart: start, tokenCount: count,
                             vector: try EmbeddingVectorBytes.decode(row.data, model: model))
            }
            guard coverage.count == chunks.count, coverage.values.allSatisfy({ $0.end == $0.total }) else { throw EmbeddingIndexError.corruptIndex }
            return result
        }
    }

    private func synchronizeDocumentEmbedding(_ id: UUID, db: ProjectDatabase) throws {
        guard let row = try db.rows("SELECT current_version FROM documents WHERE id = ?", bindings: [id.uuidString]).first,
              let version = UUID(uuidString: row[0]) else { throw EmbeddingIndexError.invalidSource }
        let key = EmbeddingSourceKey(kind: .document, externalID: id.uuidString)
        if try db.rows("SELECT revision FROM embedding_sources WHERE source_key = ?", bindings: [key.rawValue]).first?.first == version.uuidString { return }
        let snapshot = EmbeddingSourceSnapshot(key: key,
                                               revision: version.uuidString, chunks: try chunks(for: version))
        try registerEmbeddingSource(snapshot, db: db)
    }

    private func registerEmbeddingSource(_ snapshot: EmbeddingSourceSnapshot, db: ProjectDatabase) throws {
        guard !snapshot.key.externalID.isEmpty, !snapshot.key.externalID.contains("\0"), !snapshot.revision.isEmpty,
              !snapshot.revision.contains("\0"), Set(snapshot.chunks.map(\.id)).count == snapshot.chunks.count,
              snapshot.chunks.enumerated().allSatisfy({ $0.offset == $0.element.ordinal && $0.element.sourceID == snapshot.key.chunkSourceID && !$0.element.text.isEmpty }) else {
            throw EmbeddingIndexError.invalidSource
        }
        let key = snapshot.key.rawValue
        if try db.rows("SELECT revision FROM embedding_sources WHERE source_key = ?", bindings: [key]).first?.first == snapshot.revision { return }
        try db.execute("INSERT INTO embedding_sources VALUES (?, ?, ?, ?) ON CONFLICT(source_key) DO UPDATE SET revision = excluded.revision",
                       bindings: [key, snapshot.key.kind.rawValue, snapshot.key.externalID, snapshot.revision])
        try db.execute("DELETE FROM embedding_chunks WHERE source_key = ?", bindings: [key])
        for chunk in snapshot.chunks {
            try db.execute("INSERT INTO embedding_chunks (id, source_key, source_id, revision, ordinal, text, location) VALUES (?, ?, ?, ?, ?, ?, ?)",
                           bindings: [chunk.id, key, chunk.sourceID.uuidString, chunk.revision, String(chunk.ordinal), chunk.text,
                                      String(decoding: try JSONEncoder().encode(chunk.location), as: UTF8.self)])
        }
        try resetEmbeddingJob(key, db: db)
    }

    private func resetEmbeddingJob(_ key: String, db: ProjectDatabase) throws {
        let model = try embeddingModel(db)
        let total = try db.rows("SELECT COUNT(*) FROM embedding_chunks WHERE source_key = ?", bindings: [key])[0][0]
        let state: EmbeddingIndexState = total == "0" ? .failed : (model == nil ? .waitingForModel : .queued)
        try db.execute("INSERT INTO embedding_jobs VALUES (?, ?, ?, ?, 0, ?, ?, '') ON CONFLICT(source_key) DO UPDATE SET generation = excluded.generation, model_id = excluded.model_id, state = excluded.state, completed = 0, total = excluded.total, message = excluded.message, attempt = ''",
                       bindings: [key, UUID().uuidString, model?.id ?? "", state.rawValue, total, total == "0" ? "В источнике нет текста для индексации." : ""])
    }

    private func embeddingModel(_ db: ProjectDatabase) throws -> EmbeddingIndexModel? {
        guard let row = try db.rows("SELECT model_id, dimensions FROM embedding_active_model WHERE slot = 1").first else { return nil }
        guard let dimensions = Int(row[1]), (1...4096).contains(dimensions), !row[0].isEmpty else { throw EmbeddingIndexError.corruptIndex }
        return .init(id: row[0], dimensions: dimensions)
    }

    private func readEmbeddingJobs(_ db: ProjectDatabase, sourceKey: String? = nil, queuedFor modelID: String? = nil) throws -> [EmbeddingIndexJob] {
        var sql = "SELECT s.kind, s.external_id, s.revision, j.generation, j.model_id, j.state, j.completed, j.total, j.message FROM embedding_jobs j JOIN embedding_sources s ON s.source_key = j.source_key"
        var bindings: [String] = []
        var predicates: [String] = []
        if let sourceKey { predicates.append("s.source_key = ?"); bindings.append(sourceKey) }
        if let modelID { predicates.append("j.state = 'queued' AND j.model_id = ?"); bindings.append(modelID) }
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        sql += " ORDER BY s.source_key"
        if modelID != nil { sql += " LIMIT 1" }
        return try db.rows(sql, bindings: bindings).map { row in
            guard let kind = EmbeddingSourceKind(rawValue: row[0]), let state = EmbeddingIndexState(rawValue: row[5]),
                  let completed = Int(row[6]), let total = Int(row[7]) else { throw EmbeddingIndexError.corruptIndex }
            return .init(source: .init(kind: kind, externalID: row[1]), revision: row[2], generation: row[3], modelID: row[4], state: state, completed: completed, total: total, message: row[8])
        }
    }

    private func embeddingSnapshot(_ key: EmbeddingSourceKey, db: ProjectDatabase) throws -> EmbeddingSourceSnapshot {
        guard let revision = try db.rows("SELECT revision FROM embedding_sources WHERE source_key = ?", bindings: [key.rawValue]).first?.first else { throw EmbeddingIndexError.invalidSource }
        let chunks = try db.rows("SELECT id, source_id, revision, ordinal, text, location FROM embedding_chunks WHERE source_key = ? ORDER BY ordinal", bindings: [key.rawValue]).map { row -> KnowledgeChunk in
            guard let sourceID = UUID(uuidString: row[1]), let ordinal = Int(row[3]) else { throw EmbeddingIndexError.corruptIndex }
            return .init(id: row[0], sourceID: sourceID, revision: row[2], ordinal: ordinal, text: row[4], location: try JSONDecoder().decode(KnowledgeLocation.self, from: Data(row[5].utf8)))
        }
        return .init(key: key, revision: revision, chunks: chunks)
    }

    private func embeddingDocumentIsCurrent(_ snapshot: EmbeddingSourceSnapshot, db: ProjectDatabase) throws -> Bool {
        if snapshot.key.kind != .document { return true }
        return try db.rows("SELECT current_version FROM documents WHERE id = ?", bindings: [snapshot.key.externalID]).first?.first == snapshot.revision
    }

    private func embeddingLeaseIsCurrent(_ lease: EmbeddingIndexLease, db: ProjectDatabase) throws -> Bool {
        guard try embeddingModel(db) == lease.model, try embeddingDocumentIsCurrent(lease.snapshot, db: db) else { return false }
        let rows = try db.rows("SELECT s.revision FROM embedding_jobs j JOIN embedding_sources s ON s.source_key = j.source_key WHERE j.source_key = ? AND j.generation = ? AND j.attempt = ? AND j.model_id = ? AND j.state = 'running'",
                              bindings: [lease.job.source.rawValue, lease.job.generation, lease.attempt, lease.model.id])
        return rows.first?.first == lease.snapshot.revision
    }
}
