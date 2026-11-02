import Foundation
import Testing
@testable import golos_meet

@MainActor @Suite struct SQLiteFaultExpectationTests {
    private enum Sentinel: Error { case body }
    private func fault(_ db: ProjectDatabase) {
        #expect(throws: ProjectStoreError.self) { try db.execute("UPDATE journal SET value='changed'") }
    }
    private func rejectedExpectation(_ body: () -> Void) async {
        await confirmation("Exactly one assertion from the allowance helper must reject the operation", expectedCount: 1) { confirmed in
            withKnownIssue("This negative control requires the helper to reject a missing or nonunique fault") {
                body()
            } matching: { issue in
                guard case .expectationFailed(let expectation) = issue.kind,
                      expectation.sourceLocation.fileName == "SQLiteFixtureScope.swift" else { return false }
                confirmed()
                return true
            }
        }
    }
    private func closed(_ scope: SQLiteFixtureScope, faults: Int, accepted: Int) {
        #expect(scope.trace.filter { $0["stage"] == "sqlite-failure" }.count == faults)
        #expect(scope.trace.filter { $0["stage"] == "expected-sqlite-failure" }.count == accepted)
        #expect(scope.trace.filter { $0["stage"] == "closed" && $0["result"] == "0" }.count == 2)
        #expect(scope.trace.contains { $0["stage"] == "root-removed" && $0["exists"] == "false" })
    }
    @Test func nestedExpectationRejectsMissingOuterFaultAfterInnerConsumedSoleEvent() async throws {
        let scope = SQLiteFixtureScope(test: "p2-nested-missing-outer")
        try await withConnections(scope) { db, id, _ in
            await rejectedExpectation {
                scope.expectingFailure(connection: id, phase: .step, operation: .update, result: 19, extended: 1811) {
                    scope.expectingFailure(connection: id, phase: .step, operation: .update, result: 19, extended: 1811) { fault(db) }
                }
            }
        }
        try await scope.finish()
        closed(scope, faults: 1, accepted: 1)
    }
    private func withConnections(_ scope: SQLiteFixtureScope, _ body: (ProjectDatabase, UUID, ProjectDatabase) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fault-expectation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scope.register(root: root)
        let url = root.appendingPathComponent("knowledge.sqlite")
        let (db, id) = try scope.openConnection(at: url), (foreign, _) = try scope.openConnection(at: url)
        try db.execute("CREATE TABLE journal(value TEXT NOT NULL)")
        try db.execute("INSERT INTO journal VALUES ('original')")
        try db.execute("CREATE TRIGGER immutable_update BEFORE UPDATE ON journal BEGIN SELECT RAISE(ABORT, 'immutable'); END")
        try db.execute("CREATE TRIGGER immutable_delete BEFORE DELETE ON journal BEGIN SELECT RAISE(ABORT, 'immutable'); END")
        try await body(db, id, foreign)
        #expect(try db.rows("SELECT value FROM journal") == [["original"]])
    }
    @Test(arguments: ["before-inner", "after-inner"])
    func nestedExpectationsAcceptTwoDistinctNativeFaults(_ order: String) async throws {
        let scope = SQLiteFixtureScope(test: "p2-two-faults-\(order)")
        try await withConnections(scope) { db, id, _ in
            scope.expectingFailure(connection: id, phase: .step, operation: .update, result: 19, extended: 1811) {
                if order == "before-inner" { fault(db) }
                scope.expectingFailure(connection: id, phase: .step, operation: .update, result: 19, extended: 1811) { fault(db) }
                if order == "after-inner" { fault(db) }
            }
        }
        try await scope.finish()
        closed(scope, faults: 2, accepted: 2)
    }
    @Test(arguments: [0, 2])
    func exactOneExpectationRejectsMissingAndDuplicateNativeFaults(_ count: Int) async throws {
        let scope = SQLiteFixtureScope(test: "p2-cardinality-\(count)")
        try await withConnections(scope) { db, id, _ in
            await rejectedExpectation {
                scope.expectingFailure(connection: id, phase: .step, operation: .update, result: 19, extended: 1811) {
                    for _ in 0..<count { fault(db) }
                }
            }
        }
        if count == 0 { try await scope.finish() }
        else { await #expect(throws: SQLiteFixtureScope.FixtureError.sqliteFailures) { try await scope.finish() } }
        closed(scope, faults: count, accepted: 0)
    }
    @Test(arguments: ["foreign", "late", "extra", "wrong-operation", "wrong-code", "wrong-phase"])
    func allowanceDoesNotAbsorbForeignLateExtraOrMismatchedFault(_ mode: String) async throws {
        let scope = SQLiteFixtureScope(test: "p2-boundary-\(mode)")
        try await withConnections(scope) { db, id, foreign in
            let operation = {
                scope.expectingFailure(connection: id, phase: mode == "wrong-phase" ? .prepare : .step,
                    operation: .update, result: 19, extended: mode == "wrong-code" ? 1555 : 1811) {
                    if mode == "foreign" { fault(foreign) }
                    if mode == "wrong-operation" { #expect(throws: ProjectStoreError.self) { try db.execute("DELETE FROM journal") } }
                    else { fault(db) }
                    if mode == "extra" { fault(db) }
                }
            }
            if ["foreign", "late"].contains(mode) { operation() }
            else { await rejectedExpectation(operation) }
            if mode == "late" { fault(db) }
        }
        await #expect(throws: SQLiteFixtureScope.FixtureError.sqliteFailures) { try await scope.finish() }
        closed(scope, faults: ["foreign", "late", "extra"].contains(mode) ? 2 : 1,
               accepted: ["foreign", "late"].contains(mode) ? 1 : 0)
    }
    @Test func thrownBodyKeepsOriginalErrorAfterAcceptingOneNewFault() async throws {
        let scope = SQLiteFixtureScope(test: "p2-body-error")
        await #expect(throws: Sentinel.body) {
            try await withConnections(scope) { db, id, _ in
                try scope.expectingFailure(connection: id, phase: .step, operation: .update, result: 19, extended: 1811) {
                    fault(db); throw Sentinel.body
                }
            }
        }
        try await scope.finish()
        closed(scope, faults: 1, accepted: 1)
    }
    private func parallelCase(_ index: Int) async throws -> UUID {
        let scope = SQLiteFixtureScope(test: "p2-parallel-\(index)")
        var connection: UUID?
        try await withConnections(scope) { db, id, _ in
            connection = id
            for _ in 0..<8 { await Task.yield() }
            scope.expectingFailure(connection: id, phase: .step, operation: .update, result: 19, extended: 1811) { fault(db) }
        }
        try await scope.finish()
        closed(scope, faults: 1, accepted: 1)
        return try #require(connection)
    }
    @Test func twelveOverlappingNativeScopesKeepSingleUseAcceptancesSeparate() async throws {
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for i in 0..<12 { group.addTask { @MainActor in try await parallelCase(i) } }
            var ids: [UUID] = []
            for try await id in group { ids.append(id) }
            return ids
        }
        #expect(ids.count == 12 && Set(ids).count == 12)
    }
}
