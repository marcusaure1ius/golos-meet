import Foundation
@testable import golos_meet

nonisolated func removeAssignmentMigrationObjects(_ url: URL) throws {
    let db = try ProjectDatabase(url: url)
    for row in try db.rows("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'assignment_%'") {
        try db.execute("DROP TRIGGER \(row[0])")
    }
    try db.execute("DROP TABLE assignment_epoch")
}
