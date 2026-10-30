import Foundation
import SQLite3
import Testing
@testable import golos_meet

@Suite struct ProjectDatabaseDiagnosticsTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-diagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func failure(_ work: () throws -> Void) throws -> ProjectDatabase.Diagnostic {
        do { try work() }
        catch let error as ProjectStoreError {
            guard case .database(let message) = error else { throw error }
            let diagnostic = try JSONDecoder().decode(ProjectDatabase.Diagnostic.self, from: Data(message.utf8))
            #expect(diagnostic.elapsedMilliseconds >= 0)
            #expect(!message.contains("PRIVATE"))
            #expect(!message.contains("/Users/"))
            #expect(!message.contains("INSERT INTO"))
            #expect(error.localizedDescription == "Не удалось открыть или сохранить библиотеку проектов. Проверьте доступ к диску и повторите попытку.")
            return diagnostic
        }
        Issue.record("Expected a real SQLite failure")
        throw CocoaError(.coderInvalidValue)
    }

    @Test func prepareAndBindFailuresExcludeSQLNamesPathsAndValues() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try ProjectDatabase(url: root.appendingPathComponent("PRIVATE-knowledge.sqlite"))
        let prepare = try failure {
            _ = try db.rows("SELECT * FROM \"PRIVATE /Users/synthetic/document\" WHERE value = ?", bindings: ["PRIVATE secret"])
        }
        #expect(prepare.phase == .prepare && prepare.operation == .select)
        #expect(prepare.result == SQLITE_ERROR && prepare.extended == SQLITE_ERROR)
        #expect(prepare.transaction == nil && prepare.transactionPhase == nil)
        try db.execute("CREATE TABLE fixture(value TEXT)")
        let textBind = try failure {
            try db.execute("INSERT INTO fixture VALUES (?)", bindings: ["PRIVATE text", "PRIVATE extra"])
        }
        #expect(textBind.phase == .bind && textBind.operation == .insert)
        #expect(textBind.result == SQLITE_RANGE && textBind.extended == SQLITE_RANGE)
        let blobBind = try failure {
            try db.execute("INSERT INTO fixture VALUES (?)", bindings: ["PRIVATE text"], blob: Data("PRIVATE bytes".utf8))
        }
        #expect(blobBind.phase == .bind && blobBind.operation == .insert)
        #expect(blobBind.result == SQLITE_RANGE && blobBind.extended == SQLITE_RANGE)
        #expect(prepare.connection == textBind.connection && textBind.connection == blobBind.connection)
        #expect(try db.rows("SELECT * FROM fixture").isEmpty)
    }

    @Test func stepConstraintKeepsExtendedCodeAndRollsBackEarlierWrite() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try ProjectDatabase(url: root.appendingPathComponent("knowledge.sqlite"))
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute("CREATE TABLE parent(id TEXT PRIMARY KEY)")
        try db.execute("CREATE TABLE child(id TEXT REFERENCES parent(id))")
        let diagnostic = try failure {
            try db.transaction {
                try db.execute("INSERT INTO parent VALUES (?)", bindings: ["PRIVATE retained only until rollback"])
                try db.execute("INSERT INTO child VALUES (?)", bindings: ["PRIVATE missing parent"])
            }
        }
        #expect(diagnostic.phase == .step && diagnostic.operation == .insert)
        #expect(diagnostic.result == SQLITE_CONSTRAINT)
        #expect(diagnostic.extended == 787) // SQLITE_CONSTRAINT_FOREIGNKEY
        #expect(diagnostic.transaction != nil && diagnostic.transactionPhase == .work)
        #expect(try #require(diagnostic.transactionElapsedMilliseconds) >= diagnostic.elapsedMilliseconds)
        // Check durable state through a different real connection after rollback.
        let reopened = try ProjectDatabase(url: root.appendingPathComponent("knowledge.sqlite"))
        #expect(try reopened.rows("SELECT * FROM parent").isEmpty)
        #expect(try reopened.rows("SELECT * FROM child").isEmpty)
        try db.transaction { try db.execute("INSERT INTO parent VALUES ('safe')") }
        #expect(try reopened.rows("SELECT * FROM parent") == [["safe"]])
    }

    @Test func busyBeginReportsWaitAndKeepsTwoSecondTimeoutWithoutRetry() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        let db = try ProjectDatabase(url: url)
        try db.execute("CREATE TABLE fixture(value TEXT)")
        var held: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &held, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
        defer { sqlite3_exec(held, "ROLLBACK", nil, nil, nil); sqlite3_close(held) }
        try #require(sqlite3_exec(held, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        var bodyRan = false
        // Hold the lock until SQLite returns: no scheduler-dependent release deadline.
        let diagnostic = try failure { try db.transaction { bodyRan = true } }
        #expect(!bodyRan)
        #expect(diagnostic.phase == .step && diagnostic.operation == .beginImmediate)
        #expect(diagnostic.result == SQLITE_BUSY && diagnostic.extended == SQLITE_BUSY)
        #expect(diagnostic.elapsedMilliseconds >= 1800)
        #expect(diagnostic.transactionPhase == .begin && diagnostic.transaction != nil)
        #expect(sqlite3_get_autocommit(db.handle) == 1)
        #expect(sqlite3_exec(held, "COMMIT", nil, nil, nil) == SQLITE_OK)
        #expect(try db.rows("PRAGMA busy_timeout") == [["2000"]])
        try db.transaction { try db.execute("INSERT INTO fixture VALUES ('after release')") }
        #expect(try db.rows("SELECT value FROM fixture") == [["after release"]])
    }

    @Test func commitErrorSurvivesFailedCleanupAndConnectionRemainsUsable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try ProjectDatabase(url: root.appendingPathComponent("knowledge.sqlite"))
        try db.execute("CREATE TABLE fixture(value TEXT)")
        let diagnostic = try failure {
            try db.transaction {
                try db.execute("INSERT INTO fixture VALUES (?)", bindings: ["PRIVATE rolled back"])
                // End the transaction to force both the wrapper COMMIT and cleanup ROLLBACK to fail.
                try db.execute("ROLLBACK")
            }
        }
        #expect(diagnostic.phase == .step && diagnostic.operation == .commit)
        #expect(diagnostic.result == SQLITE_ERROR && diagnostic.extended == SQLITE_ERROR)
        #expect(diagnostic.transactionPhase == .commit)
        #expect(try db.rows("SELECT * FROM fixture").isEmpty)
        try db.transaction { try db.execute("INSERT INTO fixture VALUES ('safe')") }
        #expect(try db.rows("SELECT * FROM fixture") == [["safe"]])
        let outside = try failure { try db.execute("COMMIT") }
        #expect(outside.transaction == nil && outside.transactionPhase == nil)
        #expect(outside.connection == diagnostic.connection)
    }

    @Test func openFailureExcludesPersonalPath() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("PRIVATE /Users/synthetic/library")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let diagnostic = try failure { _ = try ProjectDatabase(url: directory) }
        #expect(diagnostic.phase == .open && diagnostic.operation == .open)
        #expect(diagnostic.result == SQLITE_CANTOPEN)
        #expect(diagnostic.extended & 0xff == SQLITE_CANTOPEN)
        #expect(diagnostic.transaction == nil)
    }
}
