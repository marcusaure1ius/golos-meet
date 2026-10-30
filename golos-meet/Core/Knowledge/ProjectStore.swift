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
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
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
                sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
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
        guard version <= 1 else { throw ProjectStoreError.newerSchema(version) }
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
        database = db
        return db
    }
}
