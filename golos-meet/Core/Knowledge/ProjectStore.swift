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

    func execute(_ sql: String, bindings: [String] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
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

    private func prepare(_ sql: String, bindings: [String]) throws -> OpaquePointer {
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
        guard version <= 2 else { throw ProjectStoreError.newerSchema(version) }
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
