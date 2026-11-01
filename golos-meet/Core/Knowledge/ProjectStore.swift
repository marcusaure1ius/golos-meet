import Foundation
import SQLite3
import os

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

/// SQLite is used only from ProjectStore's executor (or exclusively owned test connections).
/// Internal visibility permits real SQLite error/rollback tests without changing ProjectStore's API.
nonisolated final class ProjectDatabase: @unchecked Sendable {
    struct Diagnostic: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable { case open, prepare, bind, step }
        enum Operation: String, Codable, Sendable {
            case open, beginImmediate, begin, commit, rollback, select, insert, update, delete
            case pragmaUserVersion, pragmaForeignKeys, pragma, create, drop, alter, other
        }
        enum TransactionPhase: String, Codable, Sendable { case begin, work, commit, rollback }
        let connection: UUID
        let transaction: UUID?
        let phase: Phase
        let operation: Operation
        let result: Int32
        let extended: Int32
        let elapsedMilliseconds: Double
        let transactionPhase: TransactionPhase?
        let transactionElapsedMilliseconds: Double?

        var message: String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            // Fields come only from fixed enums, numeric SQLite codes/clocks and random IDs.
            guard let data = try? encoder.encode(self) else { return "SQLite diagnostic encoding failed" }
            return String(decoding: data, as: UTF8.self)
        }
    }
    private struct TransactionContext {
        let id: UUID
        let started: TimeInterval
        var phase: Diagnostic.TransactionPhase
    }
    let handle: OpaquePointer
    private static let logger = Logger(subsystem: "com.golos.meet", category: "library")
    private let connection = UUID()
    private var context: TransactionContext?
    #if DEBUG
    // Opt-in, task-scoped test observation. No global hook or busy-handler replacement.
    // Capture at connection creation so callbacks remain tied to that connection.
    @TaskLocal static var beginObserver: (@Sendable (UUID) -> Void)?
    private let capturedBeginObserver = ProjectDatabase.beginObserver
    #endif

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let started = ProcessInfo.processInfo.systemUptime
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            let error = Self.error(handle: db, connection: connection, context: nil,
                                   phase: .open, operation: .open, result: result, started: started)
            if let db { sqlite3_close(db) }
            throw error
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
        #if DEBUG
        if capturedBeginObserver != nil {
            sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
                guard let context, let statement else { return 0 }
                let owner = Unmanaged<ProjectDatabase>.fromOpaque(context).takeUnretainedValue()
                owner.observeBegin(OpaquePointer(statement))
                return 0
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        #endif
    }

    deinit {
        #if DEBUG
        if capturedBeginObserver != nil { sqlite3_trace_v2(handle, 0, nil, nil) }
        #endif
        sqlite3_close(handle)
    }

    #if DEBUG
    private func observeBegin(_ statement: OpaquePointer) {
        // SQLITE_TRACE_STMT runs INSIDE sqlite3_step when the statement begins.
        // Do not expand SQL or expose it, handles, bindings or paths to the observer.
        guard context?.phase == .begin, let sql = sqlite3_sql(statement),
              operation(String(cString: sql)) == .beginImmediate else { return }
        capturedBeginObserver?(connection)
    }
    #endif

    func execute(_ sql: String, bindings: [String] = [], blob: Data? = nil) throws {
        let statement = try prepare(sql, bindings: bindings, blob: blob)
        defer { sqlite3_finalize(statement) }
        _ = try step(statement, operation: operation(sql), rowsAllowed: false)
    }

    func rows(_ sql: String, bindings: [String] = []) throws -> [[String]] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        let operation = operation(sql)
        while try step(statement, operation: operation, rowsAllowed: true) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                guard let bytes = sqlite3_column_text(statement, column) else { return "" }
                let count = Int(sqlite3_column_bytes(statement, column))
                return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            })
        }
        return rows
    }

    /// Binary selects put the BLOB last; text decoding never touches vector bytes.
    func binaryRows(_ sql: String, bindings: [String]) throws -> [(fields: [String], data: Data)] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [(fields: [String], data: Data)] = []
        let operation = operation(sql)
        while try step(statement, operation: operation, rowsAllowed: true) == SQLITE_ROW {
            let last = sqlite3_column_count(statement) - 1
            guard last >= 0, sqlite3_column_type(statement, last) == SQLITE_BLOB,
                  let bytes = sqlite3_column_blob(statement, last) else { throw EmbeddingIndexError.corruptIndex }
            let fields = (0..<last).map { column -> String in
                guard let text = sqlite3_column_text(statement, column) else { return "" }
                return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
            }
            result.append((fields, Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, last)))))
        }
        return result
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        let previous = context
        context = .init(id: UUID(), started: ProcessInfo.processInfo.systemUptime, phase: .begin)
        defer { context = previous }
        try execute("BEGIN IMMEDIATE")
        do {
            context?.phase = .work
            let result = try work()
            context?.phase = .commit
            try execute("COMMIT")
            return result
        } catch {
            context?.phase = .rollback
            // Preserve the original failure; a rollback failure emits its own diagnostic.
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, bindings: [String], blob: Data? = nil) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let started = ProcessInfo.processInfo.systemUptime
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            let error = failure(phase: .prepare, operation: operation(sql), result: result, started: started)
            if let statement { sqlite3_finalize(statement) }
            throw error
        }
        for (index, value) in bindings.enumerated() {
            let started = ProcessInfo.processInfo.systemUptime
            let result = value.withCString {
                sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else {
                // Snapshot the extended code BEFORE finalize/rollback can replace it.
                let error = failure(phase: .bind, operation: operation(sql), result: result, started: started)
                sqlite3_finalize(statement)
                throw error
            }
        }
        if let blob {
            let started = ProcessInfo.processInfo.systemUptime
            let result = blob.withUnsafeBytes {
                sqlite3_bind_blob(statement, Int32(bindings.count + 1), $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else {
                let error = failure(phase: .bind, operation: operation(sql), result: result, started: started)
                sqlite3_finalize(statement); throw error
            }
        }
        return statement
    }

    private func step(_ statement: OpaquePointer, operation: Diagnostic.Operation, rowsAllowed: Bool) throws -> Int32 {
        let started = ProcessInfo.processInfo.systemUptime
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || (rowsAllowed && result == SQLITE_ROW) else {
            throw failure(phase: .step, operation: operation, result: result, started: started)
        }
        return result
    }

    /// Whitelist only operation names; never interpolate SQL, schema names, bindings or paths.
    private func operation(_ sql: String) -> Diagnostic.Operation {
        let words = sql.uppercased().split(whereSeparator: { $0.isWhitespace || $0 == "=" || $0 == ";" })
        guard let first = words.first else { return .other }
        switch first {
        case "BEGIN": return words.dropFirst().first == "IMMEDIATE" ? .beginImmediate : .begin
        case "COMMIT", "END": return .commit
        case "ROLLBACK": return .rollback
        case "SELECT": return .select
        case "INSERT", "REPLACE": return .insert
        case "UPDATE": return .update
        case "DELETE": return .delete
        case "PRAGMA":
            if words.dropFirst().first == "USER_VERSION" { return .pragmaUserVersion }
            if words.dropFirst().first == "FOREIGN_KEYS" { return .pragmaForeignKeys }
            return .pragma
        case "CREATE": return .create
        case "DROP": return .drop
        case "ALTER": return .alter
        default: return .other
        }
    }

    private func failure(phase: Diagnostic.Phase, operation: Diagnostic.Operation, result: Int32, started: TimeInterval) -> ProjectStoreError {
        Self.error(handle: handle, connection: connection, context: context,
                   phase: phase, operation: operation, result: result, started: started)
    }
    private static func error(handle: OpaquePointer?, connection: UUID, context: TransactionContext?,
                              phase: Diagnostic.Phase, operation: Diagnostic.Operation,
                              result: Int32, started: TimeInterval) -> ProjectStoreError {
        let extended = handle.map(sqlite3_extended_errcode) ?? result
        let now = ProcessInfo.processInfo.systemUptime
        let diagnostic = Diagnostic(connection: connection, transaction: context?.id, phase: phase,
            operation: operation, result: result, extended: extended,
            elapsedMilliseconds: max(0, (now - started) * 1000), transactionPhase: context?.phase,
            transactionElapsedMilliseconds: context.map { max(0, (now - $0.started) * 1000) })
        let message = diagnostic.message
        logger.error("SQLite failure \(message, privacy: .public)")
        return .database(message)
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
            try db.execute("INSERT INTO meeting_decisions (meeting_id, origin, generation, payload) VALUES (?, 'manual', ?, '') ON CONFLICT(meeting_id) DO UPDATE SET origin = 'manual', generation = excluded.generation, payload = ''",
                           bindings: [meetingID, UUID().uuidString])
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

    /// Synchronous nonescaping work stays on ProjectStore's executor and
    /// connection. Memory extensions never receive a handle across an await.
    func memoryTransaction<T>(validating hits: [KnowledgeSearchHit] = [], _ work: (ProjectDatabase) throws -> T) throws -> T {
        let db = try open()
        return try db.transaction {
            if let hit = hits.first { try validateKnowledgeSearchHits(hits, model: hit.model, db: db) }
            return try work(db)
        }
    }

    private func open() throws -> ProjectDatabase {
        if let database { return database }
        let db = try ProjectDatabase(url: url)
        try db.execute("PRAGMA foreign_keys = ON")
        // Acquire the migration lock BEFORE reading user_version. A connection
        // waiting behind another migrator must observe its committed version.
        try db.transaction {
            let version = Int(try db.rows("PRAGMA user_version").first?.first ?? "") ?? -1
            guard version <= ProjectMemorySchema.version else { throw ProjectStoreError.newerSchema(version) }
            guard version >= 0 else { throw ProjectStoreError.database("Invalid schema version") }
            if version == 0 {
                try db.execute("CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 200), parent_id TEXT REFERENCES projects(id), cloud_policy TEXT NOT NULL DEFAULT 'localOnly')")
                try db.execute("CREATE TABLE meeting_decisions (meeting_id TEXT PRIMARY KEY NOT NULL, origin TEXT NOT NULL CHECK(origin = 'manual'))")
                try db.execute("CREATE TABLE meeting_projects (meeting_id TEXT NOT NULL REFERENCES meeting_decisions(meeting_id), project_id TEXT NOT NULL REFERENCES projects(id), PRIMARY KEY (meeting_id, project_id))")
                try db.execute("CREATE INDEX meeting_projects_by_project ON meeting_projects(project_id)")
                try db.execute("PRAGMA user_version = 1")
            }
            if version < 2 {
                try db.execute("CREATE TABLE documents (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, current_version TEXT)")
                try db.execute("CREATE TABLE document_versions (id TEXT PRIMARY KEY NOT NULL, document_id TEXT NOT NULL REFERENCES documents(id), content_hash TEXT NOT NULL, relative_path TEXT NOT NULL UNIQUE, original_name TEXT NOT NULL, imported_at TEXT NOT NULL, warnings TEXT NOT NULL, UNIQUE(document_id, content_hash))")
                try db.execute("CREATE INDEX document_versions_by_hash ON document_versions(content_hash)")
                try db.execute("CREATE TABLE document_projects (document_id TEXT NOT NULL REFERENCES documents(id), project_id TEXT NOT NULL REFERENCES projects(id), PRIMARY KEY(document_id, project_id))")
                try db.execute("CREATE TABLE document_chunks (id TEXT PRIMARY KEY NOT NULL, version_id TEXT NOT NULL REFERENCES document_versions(id), ordinal TEXT NOT NULL, text TEXT NOT NULL, location TEXT NOT NULL)")
                try db.execute("CREATE TABLE document_imports (id TEXT PRIMARY KEY NOT NULL, filename TEXT NOT NULL, target_id TEXT, state TEXT NOT NULL, message TEXT NOT NULL, created_at TEXT NOT NULL)")
                try db.execute("PRAGMA user_version = 2")
            }
            if version < 3 {
                try db.execute("CREATE TABLE embedding_models (model_id TEXT PRIMARY KEY NOT NULL, dimensions INTEGER NOT NULL CHECK(dimensions BETWEEN 1 AND 4096))")
                try db.execute("CREATE TABLE embedding_active_model (slot INTEGER PRIMARY KEY CHECK(slot = 1), model_id TEXT NOT NULL REFERENCES embedding_models(model_id), dimensions INTEGER NOT NULL CHECK(dimensions BETWEEN 1 AND 4096))")
                try db.execute("CREATE TABLE embedding_sources (source_key TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('document','meeting')), external_id TEXT NOT NULL, revision TEXT NOT NULL, UNIQUE(kind, external_id))")
                // Deliberately no source FK: tombstones survive delete/recreate
                // and prevent an old observation of absence from being reused.
                try db.execute("CREATE TABLE embedding_source_epochs (source_key TEXT PRIMARY KEY NOT NULL, generation TEXT NOT NULL)")
                try db.execute("CREATE TABLE embedding_chunks (id TEXT PRIMARY KEY NOT NULL, source_key TEXT NOT NULL REFERENCES embedding_sources(source_key) ON DELETE CASCADE, source_id TEXT NOT NULL, revision TEXT NOT NULL, ordinal INTEGER NOT NULL, text TEXT NOT NULL, location TEXT NOT NULL, body_tokens INTEGER NOT NULL DEFAULT 0 CHECK(body_tokens >= 0), UNIQUE(source_key, ordinal))")
                try db.execute("CREATE TABLE embedding_jobs (source_key TEXT PRIMARY KEY NOT NULL REFERENCES embedding_sources(source_key) ON DELETE CASCADE, generation TEXT NOT NULL, model_id TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('waitingForModel','queued','running','ready','failed','cancelled')), completed INTEGER NOT NULL, total INTEGER NOT NULL, message TEXT NOT NULL, attempt TEXT NOT NULL DEFAULT '')")
                try db.execute("CREATE INDEX embedding_jobs_by_state ON embedding_jobs(state, source_key)")
                try db.execute("CREATE TABLE embedding_vectors (chunk_id TEXT NOT NULL REFERENCES embedding_chunks(id) ON DELETE CASCADE, model_id TEXT NOT NULL, token_start INTEGER NOT NULL CHECK(token_start >= 0), token_count INTEGER NOT NULL CHECK(token_count > 0), dimensions INTEGER NOT NULL CHECK(dimensions BETWEEN 1 AND 4096), vector BLOB NOT NULL CHECK(length(vector) = dimensions * 4), PRIMARY KEY(chunk_id, model_id, token_start))")
                try db.execute("PRAGMA user_version = 3")
            }
            if version < 4 {
                try db.execute("CREATE VIRTUAL TABLE knowledge_fts USING fts5(text, content='embedding_chunks', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')")
                try db.execute("CREATE TRIGGER knowledge_fts_insert AFTER INSERT ON embedding_chunks BEGIN INSERT INTO knowledge_fts(rowid, text) VALUES (new.rowid, new.text); END")
                try db.execute("CREATE TRIGGER knowledge_fts_delete AFTER DELETE ON embedding_chunks BEGIN INSERT INTO knowledge_fts(knowledge_fts, rowid, text) VALUES ('delete', old.rowid, old.text); END")
                try db.execute("CREATE TRIGGER knowledge_fts_update AFTER UPDATE OF text ON embedding_chunks BEGIN INSERT INTO knowledge_fts(knowledge_fts, rowid, text) VALUES ('delete', old.rowid, old.text); INSERT INTO knowledge_fts(rowid, text) VALUES (new.rowid, new.text); END")
                try db.execute("INSERT INTO knowledge_fts(knowledge_fts) VALUES ('rebuild')")
                try db.execute("CREATE TABLE knowledge_model_epoch (slot INTEGER PRIMARY KEY CHECK(slot = 1), generation TEXT NOT NULL)")
                try db.execute("INSERT INTO knowledge_model_epoch VALUES (1, hex(randomblob(16)))")
                try db.execute("CREATE TRIGGER knowledge_model_insert AFTER INSERT ON embedding_active_model BEGIN UPDATE knowledge_model_epoch SET generation = hex(randomblob(16)) WHERE slot = 1; END")
                try db.execute("CREATE TRIGGER knowledge_model_update AFTER UPDATE ON embedding_active_model WHEN old.model_id != new.model_id OR old.dimensions != new.dimensions BEGIN UPDATE knowledge_model_epoch SET generation = hex(randomblob(16)) WHERE slot = 1; END")
                try db.execute("CREATE TRIGGER knowledge_model_delete AFTER DELETE ON embedding_active_model BEGIN UPDATE knowledge_model_epoch SET generation = hex(randomblob(16)) WHERE slot = 1; END")
                try db.execute("PRAGMA user_version = 4")
            }
            if version < 5 {
                // Rebuild the parent and its M:N child together with FKs ON.
                // A real manual zero-selection remains a row, never inferred
                // from the absence of meeting_projects.
                try db.execute("CREATE TABLE meeting_decisions_v5 (meeting_id TEXT PRIMARY KEY NOT NULL, origin TEXT NOT NULL CHECK(origin IN ('manual','automatic','proposal')), generation TEXT NOT NULL, payload TEXT NOT NULL)")
                try db.execute("INSERT INTO meeting_decisions_v5 SELECT meeting_id, origin, hex(randomblob(16)), '' FROM meeting_decisions")
                try db.execute("CREATE TABLE meeting_projects_v5 (meeting_id TEXT NOT NULL REFERENCES meeting_decisions_v5(meeting_id), project_id TEXT NOT NULL REFERENCES projects(id), PRIMARY KEY(meeting_id, project_id))")
                try db.execute("INSERT INTO meeting_projects_v5 SELECT meeting_id, project_id FROM meeting_projects")
                try db.execute("DROP TABLE meeting_projects")
                try db.execute("DROP TABLE meeting_decisions")
                try db.execute("ALTER TABLE meeting_decisions_v5 RENAME TO meeting_decisions")
                try db.execute("ALTER TABLE meeting_projects_v5 RENAME TO meeting_projects")
                try db.execute("CREATE INDEX meeting_projects_by_project ON meeting_projects(project_id)")
                try db.execute("CREATE TABLE assignment_epoch (slot INTEGER PRIMARY KEY CHECK(slot = 1), generation TEXT NOT NULL)")
                try db.execute("INSERT INTO assignment_epoch VALUES (1, hex(randomblob(16)))")
                // Includes name/parent/policy changes, manual ABA and owners of
                // context documents. The epoch also serializes competing plans.
                for table in ["projects", "meeting_decisions", "meeting_projects", "document_projects"] {
                    for action in ["INSERT", "UPDATE", "DELETE"] {
                        try db.execute("CREATE TRIGGER assignment_\(table)_\(action) AFTER \(action) ON \(table) BEGIN UPDATE assignment_epoch SET generation = hex(randomblob(16)) WHERE slot = 1; END")
                    }
                }
                try db.execute("PRAGMA user_version = 5")
            }
            if version < 6 {
                try db.execute("CREATE TABLE assignment_work (meeting_id TEXT PRIMARY KEY NOT NULL, input TEXT NOT NULL, generation TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','running','current','waiting','failed','cancelled','manual')), message TEXT NOT NULL)")
                try db.execute("CREATE INDEX assignment_work_by_state ON assignment_work(state, meeting_id)")
                try db.execute("PRAGMA user_version = 6")
            }
            if version < 7 { try ProjectMemorySchema.migrate(db) }
        }
        database = db
        return db
    }
}

extension ProjectStore {
    func knowledgeSearchCatalog(scope: KnowledgeSearchScope) throws -> KnowledgeSearchCatalog {
        let db = try open()
        return try db.transaction {
            if case .project(let id) = scope,
               try db.rows("SELECT id FROM projects WHERE id = ?", bindings: [id.uuidString]).isEmpty {
                throw KnowledgeSearchError.scopeUnavailable
            }
            return .init(model: try searchModelStamp(db), sources: try searchSources(db).filter { scope.contains($0.owners) })
        }
    }

    /// Snapshot only the journal's bounded, explicitly consumed sources. Reuses
    /// the accepted catalog and validation; no parallel index or archive scan.
    func memoryUpdateInputs(_ lease: MemoryLease) throws -> MemoryUpdateGuard {
        try memoryTransaction { db in
            try MemorySQL.validate(lease, db: db)
            let model = try searchModelStamp(db)
            guard model.model != nil else { throw MemoryUpdateError.notReady }
            let hits = try lease.sources.map { ref in
                guard var source = try searchSources(db, key: ref.key).first,
                      source.job.state == .ready, source.job.modelID == model.model?.id else { throw MemoryUpdateError.notReady }
                // Preserve the immutable historical display/import metadata;
                // readiness/epoch/owners are fresh, identity is checked below.
                source = .init(observation: source.observation, job: source.job, owners: source.owners,
                               title: ref.title, document: ref.readerHit().source.document)
                return KnowledgeSearchHit(source: source, chunk: ref.chunk, model: model, scope: .all,
                    matchedWords: false, matchedMeaning: true, fileStamp: ref.fileStamp)
            }
            try validateKnowledgeSearchHits(hits, model: model, db: db)
            let value = MemoryUpdateGuard(hits: hits, checkpoint: try MemorySQL.updateCheckpoint(lease, db: db))
            try MemorySQL.validateUpdate(lease, expected: value, db: db)
            return value
        }
    }

    func knowledgeSearchModel() throws -> KnowledgeSearchModelStamp { try searchModelStamp(open()) }

    /// Invalid transcripts have been removed from the searchable catalog, but
    /// their warning still belongs to the current project/Inbox, not all scopes.
    func knowledgeInvalidSourceCount(_ keys: [EmbeddingSourceKey], scope: KnowledgeSearchScope) throws -> Int {
        let db = try open()
        return try db.transaction {
            try Set(keys).filter { key in
                if scope == .all { return true }
                let sql = key.kind == .meeting ? "SELECT project_id FROM meeting_projects WHERE meeting_id = ?" : "SELECT project_id FROM document_projects WHERE document_id = ?"
                let owners = try Set(db.rows(sql, bindings: [key.externalID]).map { row in
                    guard let id = UUID(uuidString: row[0]) else { throw EmbeddingIndexError.corruptIndex }; return id
                })
                return scope.contains(owners)
            }.count
        }
    }

    func knowledgeLexicalSearch(expression: String, scope: KnowledgeSearchScope) throws -> [KnowledgeSearchChunk] {
        let db = try open()
        var predicate = "", bindings = [expression]
        switch scope {
        case .all: break
        case .inbox:
            predicate = " AND ((s.kind = 'meeting' AND NOT EXISTS (SELECT 1 FROM meeting_projects p WHERE p.meeting_id = s.external_id)) OR (s.kind = 'document' AND NOT EXISTS (SELECT 1 FROM document_projects p WHERE p.document_id = s.external_id)))"
        case .project(let id):
            predicate = " AND ((s.kind = 'meeting' AND EXISTS (SELECT 1 FROM meeting_projects p WHERE p.meeting_id = s.external_id AND p.project_id = ?)) OR (s.kind = 'document' AND EXISTS (SELECT 1 FROM document_projects p WHERE p.document_id = s.external_id AND p.project_id = ?)))"
            bindings += [id.uuidString, id.uuidString]
        }
        let sql = "SELECT s.kind, s.external_id, c.id, c.source_id, c.revision, c.ordinal, c.text, c.location FROM knowledge_fts JOIN embedding_chunks c ON c.rowid = knowledge_fts.rowid JOIN embedding_sources s ON s.source_key = c.source_key LEFT JOIN documents d ON s.kind = 'document' AND d.id = s.external_id WHERE knowledge_fts MATCH ? AND (s.kind != 'document' OR d.current_version = s.revision)" + predicate + " ORDER BY bm25(knowledge_fts), c.id LIMIT 100"
        return try db.rows(sql, bindings: bindings).map { row in
            guard let kind = EmbeddingSourceKind(rawValue: row[0]), let id = UUID(uuidString: row[3]), let ordinal = Int(row[5]) else { throw EmbeddingIndexError.corruptIndex }
            return .init(source: .init(kind: kind, externalID: row[1]),
                         chunk: .init(id: row[2], sourceID: id, revision: row[4], ordinal: ordinal, text: row[6],
                                      location: try JSONDecoder().decode(KnowledgeLocation.self, from: Data(row[7].utf8))))
        }
    }

    func knowledgeVectorCount(for key: EmbeddingSourceKey) throws -> Int {
        Int(try open().rows("SELECT COUNT(*) FROM embedding_vectors v JOIN embedding_chunks c ON c.id = v.chunk_id WHERE c.source_key = ?", bindings: [key.rawValue]).first?.first ?? "") ?? 0
    }

    /// A late corrupt read may only requeue the exact generation it read.
    /// It must not reset a replacement source/model or a user's cancellation.
    func reindexCorruptSearchSource(_ source: KnowledgeSearchSource, model: KnowledgeSearchModelStamp) throws -> Bool {
        let db = try open()
        return try db.transaction {
            guard try searchModelStamp(db) == model,
                  let current = try searchSources(db, key: source.key).first,
                  source.hasSameIdentity(as: current, requiresVectors: true) else { return false }
            try resetEmbeddingJob(source.key.rawValue, db: db)
            return true
        }
    }

    func validateKnowledgeSearchHit(_ hit: KnowledgeSearchHit) throws {
        try validateKnowledgeSearchHits([hit], model: hit.model)
    }

    func validateKnowledgeSearchHits(_ hits: [KnowledgeSearchHit], model: KnowledgeSearchModelStamp) throws {
        let db = try open()
        try db.transaction { try validateKnowledgeSearchHits(hits, model: model, db: db) }
    }

    private func validateKnowledgeSearchHits(_ hits: [KnowledgeSearchHit], model: KnowledgeSearchModelStamp,
                                             db: ProjectDatabase) throws {
        guard try searchModelStamp(db) == model else { throw KnowledgeSearchError.modelChanged }
        for hit in hits {
            guard hit.model == model,
                  let source = try searchSources(db, key: hit.source.key).first,
                  hit.source.hasSameIdentity(as: source, requiresVectors: hit.matchedMeaning), hit.scope.contains(source.owners),
                  let row = try db.rows("SELECT source_id, revision, ordinal, text, location FROM embedding_chunks WHERE id = ? AND source_key = ?", bindings: [hit.id, source.key.rawValue]).first,
                  let id = UUID(uuidString: row[0]), let ordinal = Int(row[2]) else { throw KnowledgeSearchError.sourceChanged }
            let chunk = KnowledgeChunk(id: hit.id, sourceID: id, revision: row[1], ordinal: ordinal, text: row[3],
                                      location: try JSONDecoder().decode(KnowledgeLocation.self, from: Data(row[4].utf8)))
            guard chunk == hit.chunk else { throw KnowledgeSearchError.sourceChanged }
        }
    }

    /// Policies, owners, model and selected chunks are read in ONE transaction.
    /// The existing assignment epoch fences policy/owner ABA as well as project
    /// recreation. Unrelated assignment changes conservatively invalidate too.
    func questionCheckpoint(projectID: UUID, hits: [KnowledgeSearchHit]) throws -> KnowledgeQuestionCheckpoint {
        let db = try open()
        return try db.transaction {
            if let first = hits.first {
                guard hits.allSatisfy({ $0.scope == .project(projectID) }) else { throw KnowledgeAnswerError.foreignContext }
                try validateKnowledgeSearchHits(hits, model: first.model, db: db)
            }
            let ids = hits.reduce(into: Set([projectID])) { $0.formUnion($1.source.owners) }
            let projects = try ids.sorted(by: { $0.uuidString < $1.uuidString }).map { id in
                guard let row = try db.rows("SELECT name, parent_id, cloud_policy FROM projects WHERE id = ?", bindings: [id.uuidString]).first,
                      let policy = ProjectCloudPolicy(rawValue: row[2]) else { throw KnowledgeAnswerError.cloudNotAllowed }
                return KnowledgeProject(id: id, name: row[0], parentID: UUID(uuidString: row[1]), cloudPolicy: policy)
            }
            guard let epoch = try db.rows("SELECT generation FROM assignment_epoch WHERE slot = 1").first?.first else { throw EmbeddingIndexError.corruptIndex }
            return .init(epoch: epoch, projects: projects)
        }
    }

    func setCloudPolicy(_ policy: ProjectCloudPolicy, for projectID: UUID) throws {
        let db = try open()
        try db.transaction {
            try requireProject(projectID, db: db)
            try db.execute("UPDATE projects SET cloud_policy = ? WHERE id = ?", bindings: [policy.rawValue, projectID.uuidString])
        }
    }

    private func searchModelStamp(_ db: ProjectDatabase) throws -> KnowledgeSearchModelStamp {
        guard let epoch = try db.rows("SELECT generation FROM knowledge_model_epoch WHERE slot = 1").first?.first, !epoch.isEmpty else { throw EmbeddingIndexError.corruptIndex }
        return .init(model: try embeddingModel(db), generation: epoch)
    }

    private func searchSources(_ db: ProjectDatabase, key: EmbeddingSourceKey? = nil) throws -> [KnowledgeSearchSource] {
        var sql = "SELECT s.kind, s.external_id, s.revision, e.generation, j.generation, j.model_id, j.state, j.completed, j.total, j.message, COALESCE(d.title, '') FROM embedding_sources s JOIN embedding_source_epochs e ON e.source_key = s.source_key JOIN embedding_jobs j ON j.source_key = s.source_key LEFT JOIN documents d ON s.kind = 'document' AND d.id = s.external_id WHERE (s.kind != 'document' OR d.current_version = s.revision)"
        if key != nil { sql += " AND s.source_key = ?" }
        sql += " ORDER BY s.source_key"
        return try db.rows(sql, bindings: key.map { [$0.rawValue] } ?? []).map { row in
            guard let kind = EmbeddingSourceKind(rawValue: row[0]), let state = EmbeddingIndexState(rawValue: row[6]),
                  let completed = Int(row[7]), let total = Int(row[8]) else { throw EmbeddingIndexError.corruptIndex }
            let source = EmbeddingSourceKey(kind: kind, externalID: row[1])
            let ownerSQL = kind == .meeting ? "SELECT project_id FROM meeting_projects WHERE meeting_id = ?" : "SELECT project_id FROM document_projects WHERE document_id = ?"
            let owners = try Set(db.rows(ownerSQL, bindings: [source.externalID]).map { owner in
                guard let id = UUID(uuidString: owner[0]) else { throw EmbeddingIndexError.corruptIndex }; return id
            })
            let version: DocumentVersion?
            if kind == .document {
                guard let id = UUID(uuidString: source.externalID),
                      let current = try readVersions(id, db: db).first(where: { $0.id.uuidString == row[2] }) else { throw EmbeddingIndexError.corruptIndex }
                version = current
            } else { version = nil }
            return .init(observation: .init(key: source, generation: row[3], revision: row[2]),
                         job: .init(source: source, revision: row[2], generation: row[4], modelID: row[5], state: state, completed: completed, total: total, message: row[9]),
                         owners: owners, title: kind == .document ? row[10] : "Встреча \(source.externalID)", document: version)
        }
    }

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

    func observeEmbeddingSource(_ key: EmbeddingSourceKey) throws -> EmbeddingSourceObservation {
        guard !key.externalID.isEmpty, !key.externalID.contains("\0") else { throw EmbeddingIndexError.invalidSource }
        let db = try open()
        return try db.transaction {
            try db.execute("INSERT INTO embedding_source_epochs VALUES (?, ?) ON CONFLICT(source_key) DO NOTHING",
                           bindings: [key.rawValue, UUID().uuidString])
            guard let observation = try embeddingObservation(key, db: db) else { throw EmbeddingIndexError.corruptIndex }
            return observation
        }
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
    func synchronizeMeetingEmbedding(_ snapshot: EmbeddingSourceSnapshot, replacing observation: EmbeddingSourceObservation) throws -> Bool {
        guard snapshot.key.kind == .meeting, observation.key == snapshot.key else { throw EmbeddingIndexError.invalidSource }
        let db = try open()
        return try db.transaction {
            guard try embeddingObservation(snapshot.key, db: db) == observation else { return false }
            try registerEmbeddingSource(snapshot, db: db)
            return true
        }
    }

    /// Call after a source is deleted or a meeting transcript is found invalid.
    /// Cascades invalidate outstanding leases and remove its derived data only.
    func removeEmbeddingSource(_ key: EmbeddingSourceKey) throws {
        let db = try open()
        try db.transaction {
            try db.execute("DELETE FROM embedding_sources WHERE source_key = ?", bindings: [key.rawValue])
            try advanceEmbeddingCatalog(key, db: db)
        }
    }

    @discardableResult
    func invalidateMeetingEmbedding(_ key: EmbeddingSourceKey, replacing observation: EmbeddingSourceObservation) throws -> Bool {
        guard key.kind == .meeting, observation.key == key else { throw EmbeddingIndexError.invalidSource }
        let db = try open()
        return try db.transaction {
            guard try embeddingObservation(key, db: db) == observation else { return false }
            try db.execute("DELETE FROM embedding_sources WHERE source_key = ?", bindings: [key.rawValue])
            try advanceEmbeddingCatalog(key, db: db)
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
    func claimEmbeddingJob(after sourceKey: String? = nil) throws -> EmbeddingIndexLease? {
        let db = try open()
        return try db.transaction {
            guard let model = try embeddingModel(db),
                  let job = try (readEmbeddingJobs(db, queuedFor: model.id, after: sourceKey).first
                    ?? readEmbeddingJobs(db, queuedFor: model.id).first) else { return nil }
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

    func cancelPendingEmbeddingJobs() throws {
        try open().execute("UPDATE embedding_jobs SET state = 'cancelled', generation = hex(randomblob(16)), attempt = '', message = 'Индексирование отменено.' WHERE state IN ('queued','running','waitingForModel')")
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

    /// Release only this live attempt, e.g. on worker shutdown/supersession.
    /// A user's cancel or a new source/model generation must remain untouched.
    func interruptEmbeddingJob(_ lease: EmbeddingIndexLease) throws {
        let db = try open()
        try db.transaction {
            guard try embeddingLeaseIsCurrent(lease, db: db) else { return }
            try resetEmbeddingJob(lease.job.source.rawValue, db: db)
        }
    }

    func embeddingQueueSummary() throws -> (jobs: [EmbeddingIndexJob], counts: [EmbeddingIndexState: Int]) {
        let db = try open()
        return try db.transaction {
            var counts: [EmbeddingIndexState: Int] = [:]
            for row in try db.rows("SELECT state, COUNT(*) FROM embedding_jobs GROUP BY state") {
                guard let state = EmbeddingIndexState(rawValue: row[0]), let count = Int(row[1]) else { throw EmbeddingIndexError.corruptIndex }
                counts[state] = count
            }
            return (try readEmbeddingJobs(db, uiLimit: 30), counts)
        }
    }

    func embeddingDocumentTitles() throws -> [EmbeddingSourceKey: String] {
        var titles: [EmbeddingSourceKey: String] = [:]
        for row in try open().rows("SELECT id, title FROM documents") {
            titles[.init(kind: .document, externalID: row[0])] = row[1]
        }
        return titles
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
        try advanceEmbeddingCatalog(snapshot.key, db: db)
    }

    private func embeddingObservation(_ key: EmbeddingSourceKey, db: ProjectDatabase) throws -> EmbeddingSourceObservation? {
        guard let row = try db.rows("SELECT e.generation, s.revision FROM embedding_source_epochs e LEFT JOIN embedding_sources s ON s.source_key = e.source_key WHERE e.source_key = ?", bindings: [key.rawValue]).first else { return nil }
        guard !row[0].isEmpty else { throw EmbeddingIndexError.corruptIndex }
        return .init(key: key, generation: row[0], revision: row[1].isEmpty ? nil : row[1])
    }

    private func advanceEmbeddingCatalog(_ key: EmbeddingSourceKey, db: ProjectDatabase) throws {
        try db.execute("INSERT INTO embedding_source_epochs VALUES (?, ?) ON CONFLICT(source_key) DO UPDATE SET generation = excluded.generation",
                       bindings: [key.rawValue, UUID().uuidString])
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

    private func readEmbeddingJobs(_ db: ProjectDatabase, sourceKey: String? = nil, queuedFor modelID: String? = nil,
                                   after: String? = nil, uiLimit: Int? = nil) throws -> [EmbeddingIndexJob] {
        var sql = "SELECT s.kind, s.external_id, s.revision, j.generation, j.model_id, j.state, j.completed, j.total, j.message FROM embedding_jobs j JOIN embedding_sources s ON s.source_key = j.source_key"
        var bindings: [String] = []
        var predicates: [String] = []
        if let sourceKey { predicates.append("s.source_key = ?"); bindings.append(sourceKey) }
        if let modelID { predicates.append("j.state = 'queued' AND j.model_id = ?"); bindings.append(modelID) }
        if let after { predicates.append("s.source_key > ?"); bindings.append(after) }
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        sql += uiLimit == nil ? " ORDER BY s.source_key" : " ORDER BY CASE j.state WHEN 'running' THEN 0 WHEN 'failed' THEN 1 WHEN 'queued' THEN 2 WHEN 'waitingForModel' THEN 3 WHEN 'cancelled' THEN 4 ELSE 5 END, s.source_key"
        if modelID != nil { sql += " LIMIT 1" }
        if let uiLimit { sql += " LIMIT \(uiLimit)" }
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


extension ProjectStore {
    func meetingAssignmentCheckpoint() throws -> MeetingAssignmentCheckpoint {
        let db = try open()
        return try db.transaction { try assignmentCheckpoint(db) }
    }

    private func assignmentCheckpoint(_ db: ProjectDatabase) throws -> MeetingAssignmentCheckpoint {
        let projects = try db.rows("SELECT id, name, parent_id, cloud_policy FROM projects ORDER BY id").map { row in
            guard let id = UUID(uuidString: row[0]), let policy = ProjectCloudPolicy(rawValue: row[3]) else { throw EmbeddingIndexError.corruptIndex }
            return KnowledgeProject(id: id, name: row[1], parentID: UUID(uuidString: row[2]), cloudPolicy: policy)
        }
        var decisions: [String: MeetingAssignmentDecision] = [:]
        for row in try db.rows("SELECT meeting_id, origin, generation, payload FROM meeting_decisions") {
            guard let origin = MeetingAssignmentOrigin(rawValue: row[1]) else { throw EmbeddingIndexError.corruptIndex }
            decisions[row[0]] = .init(origin: origin, generation: row[2], result: row[3].isEmpty ? nil :
                try JSONDecoder().decode(MeetingAssignmentResult.self, from: Data(row[3].utf8)))
        }
        guard let epoch = try db.rows("SELECT generation FROM assignment_epoch WHERE slot = 1").first?.first else { throw EmbeddingIndexError.corruptIndex }
        // Links survive a missing/invalid transcript. Do not let its removal
        // from the searchable catalog silently shrink classification context.
        let contextKeys = try Set(db.rows("SELECT 'meeting', p.meeting_id FROM meeting_projects p JOIN meeting_decisions d ON d.meeting_id=p.meeting_id WHERE d.origin='manual' UNION SELECT 'document', p.document_id FROM document_projects p JOIN documents d ON d.id=p.document_id WHERE d.current_version IS NOT NULL").map { row in
            guard let kind = EmbeddingSourceKind(rawValue: row[0]) else { throw EmbeddingIndexError.corruptIndex }
            return EmbeddingSourceKey(kind: kind, externalID: row[1])
        })
        return .init(epoch: epoch, projects: projects, model: try searchModelStamp(db), sources: try searchSources(db), decisions: decisions, contextKeys: contextKeys)
    }

    /// One transaction checks the WHOLE context, not just the target's owners.
    /// The service separately fences filesystem changes before entering here.
    func commitMeetingAssignment(_ result: MeetingAssignmentResult, meetingID: String,
                                 checkpoint: MeetingAssignmentCheckpoint, runtimeLease: MeetingAssignmentLease? = nil) throws -> MeetingAssignmentCommit {
        try Task.checkCancellation()
        let db = try open()
        return try db.transaction {
            let current = try assignmentCheckpoint(db)
            if let runtimeLease {
                guard runtimeLease.work.meetingID == meetingID, try assignmentLeaseIsCurrent(runtimeLease, db: db) else { return .superseded }
            }
            if current.decisions[meetingID]?.origin == .manual { return .manual }
            guard current == checkpoint, current.sources.contains(where: { $0.key == .init(kind: .meeting, externalID: meetingID) && $0.job.state == .ready }) else { return .superseded }
            guard result.modelID == checkpoint.model.model?.id, result.dimensions == checkpoint.model.model?.dimensions,
                  result.modelGeneration == checkpoint.model.generation,
                  result.algorithm == MeetingAssignmentPolicy.algorithm,
                  result.assignedProjectIDs == Set(result.evidence.filter(MeetingAssignmentPolicy.confident).map(\.projectID)),
                  result.assignedProjectIDs.isSubset(of: Set(current.projects.map(\.id))) else { throw MeetingAssignmentError.stale }
            let origin: MeetingAssignmentOrigin = result.assignedProjectIDs.isEmpty ? .proposal : .automatic
            if current.decisions[meetingID]?.origin == origin, current.decisions[meetingID]?.result == result,
               current.sources.first(where: { $0.key == .init(kind: .meeting, externalID: meetingID) })?.owners == result.assignedProjectIDs {
                if let runtimeLease { try finishAssignmentWork(runtimeLease, state: .current, message: "", db: db) }
                return .unchanged
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let payload = String(decoding: try encoder.encode(result), as: UTF8.self)
            try db.execute("INSERT INTO meeting_decisions (meeting_id, origin, generation, payload) VALUES (?, ?, ?, ?) ON CONFLICT(meeting_id) DO UPDATE SET origin=excluded.origin, generation=excluded.generation, payload=excluded.payload",
                           bindings: [meetingID, origin.rawValue, UUID().uuidString, payload])
            try db.execute("DELETE FROM meeting_projects WHERE meeting_id = ?", bindings: [meetingID])
            for id in result.assignedProjectIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                try db.execute("INSERT INTO meeting_projects (meeting_id, project_id) VALUES (?, ?)", bindings: [meetingID, id.uuidString])
            }
            if let runtimeLease { try finishAssignmentWork(runtimeLease, state: .current, message: "", db: db) }
            return .applied
        }
    }
}


extension ProjectStore {
    func assignmentRuntimeSnapshot() throws -> MeetingAssignmentRuntimeSnapshot {
        let db = try open()
        return try db.transaction {
            let checkpoint = try assignmentCheckpoint(db)
            let work = try readAssignmentWork(db).map { item -> MeetingAssignmentWork in
                if checkpoint.decisions[item.meetingID]?.origin == .manual {
                    return .init(meetingID: item.meetingID, input: item.input, generation: item.generation, state: .manual, message: "")
                }
                return item
            }
            return .init(work: Dictionary(uniqueKeysWithValues: work.map { ($0.meetingID, $0) }), decisions: checkpoint.decisions)
        }
    }

    func reconcileAssignmentWork(_ inputs: MeetingAssignmentInputs) throws -> Bool {
        let db = try open()
        return try db.transaction {
            guard try assignmentCheckpoint(db) == inputs.checkpoint else { return false }
            let old = Dictionary(uniqueKeysWithValues: try readAssignmentWork(db).map { ($0.meetingID, $0) })
            for (id, input) in inputs.fingerprints.sorted(by: { $0.key < $1.key }) {
                let manual = inputs.checkpoint.decisions[id]?.origin == .manual
                let previous = old[id]
                let state: MeetingAssignmentWorkState = manual ? .manual : previous?.state == .cancelled ? .cancelled : .pending
                if previous?.input != input || (manual && previous?.state != .manual) {
                    try db.execute("INSERT INTO assignment_work VALUES (?, ?, ?, ?, '') ON CONFLICT(meeting_id) DO UPDATE SET input=excluded.input, generation=excluded.generation, state=excluded.state, message=''",
                        bindings: [id, input, UUID().uuidString, state.rawValue])
                    if !manual { try clearAutomaticLinks(id, db: db) }
                } else if previous?.state != .current && !manual { try clearAutomaticLinks(id, db: db) }
            }
            return true
        }
    }

    func validateAssignmentEvidence(_ work: MeetingAssignmentWork, decision: MeetingAssignmentDecision,
                                    checkpoint: MeetingAssignmentCheckpoint) throws {
        let db = try open()
        try db.transaction {
            guard try assignmentCheckpoint(db) == checkpoint,
                  checkpoint.decisions[work.meetingID] == decision,
                  try readAssignmentWork(db).first(where: { $0.meetingID == work.meetingID }) == work,
                  work.state == .current else { throw MeetingAssignmentError.stale }
        }
    }

    func assignmentIndexUnavailable() throws {
        let db = try open()
        try db.transaction {
            try db.execute("UPDATE assignment_work SET state='waiting', input=substr(input,1,64)||'|runtime-unavailable', generation=hex(randomblob(16)), message='Для распределения нужна работающая локальная модель индексирования.' WHERE state NOT IN ('cancelled','manual') AND NOT EXISTS (SELECT 1 FROM meeting_decisions d WHERE d.meeting_id=assignment_work.meeting_id AND d.origin='manual')")
            try db.execute("DELETE FROM meeting_projects WHERE EXISTS (SELECT 1 FROM meeting_decisions d WHERE d.meeting_id=meeting_projects.meeting_id AND d.origin='automatic')")
        }
    }

    func recoverAssignmentWork() throws {
        let db = try open()
        try db.execute("UPDATE assignment_work SET state='pending', generation=hex(randomblob(16)), message='' WHERE state='running'")
    }

    func claimAssignmentWork(after cursor: String?, excluding: Set<String> = []) throws -> MeetingAssignmentLease? {
        let db = try open()
        return try db.transaction {
            let pending = try readAssignmentWork(db).filter { $0.state == .pending && !excluding.contains($0.meetingID) }
            guard let next = pending.first(where: { $0.meetingID > (cursor ?? "") }) ?? pending.first else { return nil }
            try db.execute("UPDATE assignment_work SET state='running' WHERE meeting_id=? AND generation=? AND state='pending'", bindings: [next.meetingID, next.generation])
            return .init(work: .init(meetingID: next.meetingID, input: next.input, generation: next.generation, state: .running, message: ""))
        }
    }

    func cancelAssignment(_ id: String) throws {
        let db = try open()
        try db.transaction {
            guard try db.rows("SELECT origin FROM meeting_decisions WHERE meeting_id=?", bindings: [id]).first?.first != "manual" else { return }
            try db.execute("UPDATE assignment_work SET state='cancelled', generation=hex(randomblob(16)), message='' WHERE meeting_id=?", bindings: [id])
            try clearAutomaticLinks(id, db: db)
        }
    }

    func retryAssignment(_ id: String) throws {
        let db = try open()
        try db.transaction {
            guard try db.rows("SELECT origin FROM meeting_decisions WHERE meeting_id=?", bindings: [id]).first?.first != "manual" else { return }
            try db.execute("UPDATE assignment_work SET state='pending', generation=hex(randomblob(16)), message='' WHERE meeting_id=?", bindings: [id])
            try clearAutomaticLinks(id, db: db)
        }
    }

    func interruptAssignment(_ lease: MeetingAssignmentLease, message: String = "") throws {
        let db = try open()
        try db.execute("UPDATE assignment_work SET state='pending', generation=hex(randomblob(16)), message=? WHERE meeting_id=? AND generation=? AND state='running'", bindings: [message, lease.work.meetingID, lease.work.generation])
    }

    func failAssignment(_ lease: MeetingAssignmentLease, state: MeetingAssignmentWorkState, message: String) throws {
        let db = try open()
        try db.transaction {
            guard try assignmentLeaseIsCurrent(lease, db: db) else { return }
            try finishAssignmentWork(lease, state: state, message: message, db: db)
            try clearAutomaticLinks(lease.work.meetingID, db: db)
        }
    }

    private func clearAutomaticLinks(_ id: String, db: ProjectDatabase) throws {
        try db.execute("DELETE FROM meeting_projects WHERE meeting_id=? AND EXISTS (SELECT 1 FROM meeting_decisions WHERE meeting_id=? AND origin='automatic')", bindings: [id, id])
    }
    private func assignmentLeaseIsCurrent(_ lease: MeetingAssignmentLease, db: ProjectDatabase) throws -> Bool {
        try db.rows("SELECT input FROM assignment_work WHERE meeting_id=? AND generation=? AND state='running'", bindings: [lease.work.meetingID, lease.work.generation]).first?.first == lease.work.input
    }
    private func finishAssignmentWork(_ lease: MeetingAssignmentLease, state: MeetingAssignmentWorkState, message: String, db: ProjectDatabase) throws {
        try db.execute("UPDATE assignment_work SET state=?, message=? WHERE meeting_id=? AND generation=? AND state='running'", bindings: [state.rawValue, message, lease.work.meetingID, lease.work.generation])
    }
    private func readAssignmentWork(_ db: ProjectDatabase) throws -> [MeetingAssignmentWork] {
        try db.rows("SELECT meeting_id, input, generation, state, message FROM assignment_work ORDER BY meeting_id").map { row in
            guard let state = MeetingAssignmentWorkState(rawValue: row[3]) else { throw EmbeddingIndexError.corruptIndex }
            return .init(meetingID: row[0], input: row[1], generation: row[2], state: state, message: row[4])
        }
    }
}
