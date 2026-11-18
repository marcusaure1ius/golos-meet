import Foundation

nonisolated enum ProjectMemorySchema {
    static let version = 7
    /// Called inside ProjectStore's existing migration transaction/lock. No
    /// destructive rebuild of old tables and no timeout/busy-handler changes.
    static func migrate(_ db: ProjectDatabase) throws {
        try db.execute("CREATE TABLE memory_state (project_id TEXT PRIMARY KEY NOT NULL, generation TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision >= 0))")
        try db.execute("CREATE TABLE memory_events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, project_id TEXT NOT NULL, slot TEXT NOT NULL, body TEXT NOT NULL)")
        try db.execute("CREATE INDEX memory_events_project ON memory_events(project_id, sequence)")
        try db.execute("CREATE INDEX memory_events_slot ON memory_events(project_id, slot, sequence)")
        try db.execute("CREATE TABLE memory_links (event_id TEXT NOT NULL REFERENCES memory_events(id), target_id TEXT NOT NULL REFERENCES memory_events(id), kind TEXT NOT NULL CHECK(kind IN ('related','compatible','conflicts','replaces','retracts','corrects','derivedFrom')), PRIMARY KEY(event_id, target_id, kind))")
        try db.execute("CREATE INDEX memory_links_target ON memory_links(target_id, kind)")
        try db.execute("CREATE TABLE memory_head_versions (sequence INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, slot TEXT NOT NULL, event_id TEXT NOT NULL REFERENCES memory_events(id), manual INTEGER NOT NULL CHECK(manual IN (0,1)))")
        try db.execute("CREATE INDEX memory_heads_slot ON memory_head_versions(project_id, slot, sequence)")
        try db.execute("CREATE TABLE memory_batches (project_id TEXT NOT NULL, producer_key TEXT NOT NULL, fingerprint TEXT NOT NULL, event_ids TEXT NOT NULL, PRIMARY KEY(project_id, producer_key, fingerprint))")
        for table in ["memory_events", "memory_links", "memory_head_versions", "memory_batches"] {
            for action in ["UPDATE", "DELETE"] {
                try db.execute("CREATE TRIGGER \(table)_no_\(action.lowercased()) BEFORE \(action) ON \(table) BEGIN SELECT RAISE(ABORT, 'Immutable memory history'); END")
            }
        }
        try db.execute("PRAGMA user_version = 7")
    }
}
