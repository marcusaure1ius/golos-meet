import Foundation
@testable import golos_meet

nonisolated func removeAssignmentMigrationObjects(_ url: URL) throws {
    let db = try ProjectDatabase(url: url)
    // These tests intentionally reconstruct older schemas; remove v7 objects
    // as well. A separate genuine v6 fixture tests v6→v7 without downgrading.
    for row in try db.rows("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'memory_%'") {
        try db.execute("DROP TRIGGER \(row[0])")
    }
    for table in ["memory_links", "memory_head_versions", "memory_batches", "memory_events", "memory_state"] {
        try db.execute("DROP TABLE IF EXISTS \(table)")
    }
    for row in try db.rows("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'assignment_%'") {
        try db.execute("DROP TRIGGER \(row[0])")
    }
    try db.execute("DROP TABLE assignment_epoch")
    try db.execute("DROP TABLE assignment_work")
}
