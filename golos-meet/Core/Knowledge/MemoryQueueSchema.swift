import Foundation

nonisolated enum MemoryQueueSchema {
    static let version = 8
    static func migrate(_ db: ProjectDatabase) throws {
        try db.execute("CREATE TABLE memory_queue_runtime (slot INTEGER PRIMARY KEY CHECK(slot=1), generation TEXT NOT NULL)")
        try db.execute("INSERT INTO memory_queue_runtime VALUES (1, lower(hex(randomblob(16))))")
        try db.execute("CREATE TABLE memory_queue_work (sequence INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL, source_key TEXT NOT NULL, source TEXT NOT NULL, input TEXT NOT NULL, generation TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('queued','running','partial','backpressured','waiting','denied','needsConsent','completed','insufficient','failed','limited','cancelled','stale')), cursor INTEGER NOT NULL CHECK(cursor>=0), total INTEGER NOT NULL CHECK(total>=cursor), identity TEXT NOT NULL, generator_model TEXT NOT NULL, generator_contract TEXT NOT NULL, cycle TEXT NOT NULL, dependencies TEXT NOT NULL, selected_key TEXT, message TEXT NOT NULL, attempt TEXT, UNIQUE(project_id,source_key))")
        try db.execute("CREATE INDEX memory_queue_work_state ON memory_queue_work(state,sequence)")
        try db.execute("CREATE TABLE memory_queue_batches (project_id TEXT NOT NULL, source_key TEXT NOT NULL, input TEXT NOT NULL, cycle TEXT NOT NULL, start INTEGER NOT NULL, count INTEGER NOT NULL CHECK(count>0), selected_key TEXT NOT NULL, outcome TEXT NOT NULL CHECK(outcome IN ('completed','unchanged','insufficient')), event_ids TEXT NOT NULL, PRIMARY KEY(project_id,source_key,input,cycle,start))")
        for action in ["UPDATE", "DELETE"] {
            try db.execute("CREATE TRIGGER memory_queue_batches_no_\(action.lowercased()) BEFORE \(action) ON memory_queue_batches BEGIN SELECT RAISE(ABORT,'Immutable memory queue batch'); END")
        }
        try db.execute("PRAGMA user_version=8")
    }
}
