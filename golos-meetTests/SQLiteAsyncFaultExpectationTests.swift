import Foundation
import Testing
@testable import golos_meet

@MainActor @Suite struct SQLiteAsyncFaultExpectationTests {
    private enum BodyError: Error { case sentinel }
    private func root(_ scope: SQLiteFixtureScope) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assignment-fault-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scope.register(root: root)
        return root
    }
    private func fault(_ url: URL) throws {
        let db = try ProjectDatabase(url: url)
        #expect(throws: ProjectStoreError.self) { try db.execute("CREATE TABLE sentinel(value TEXT)") }
    }
    private func setup(_ url: URL) throws {
        let db = try ProjectDatabase(url: url)
        try db.execute("CREATE TABLE sentinel(value TEXT)")
    }
    private func rejected(_ body: () async throws -> Void) async rethrows {
        try await confirmation("Exactly one allowance assertion must reject this operation", expectedCount: 1) { confirmed in
            try await withKnownIssue("Negative control of the async allowance") { try await body() } matching: { issue in
                guard case .expectationFailed(let expectation) = issue.kind,
                      expectation.sourceLocation.fileName == "SQLiteFixtureScope.swift" else { return false }
                confirmed(); return true
            }
        }
    }
    @Test(arguments: [0, 2]) func requiresOneNewNativeConnectionAtExactURL(count: Int) async throws {
        let scope = SQLiteFixtureScope(test: "async-new-connection-cardinality")
        let url = try root(scope).appendingPathComponent("knowledge.sqlite")
        try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
            try setup(url)
            try await rejected {
                try await scope.expectingFailureOnNewConnection(at: url, phase: .prepare, operation: .create, result: 1, extended: 1) {
                    for _ in 0..<count { try fault(url) }
                }
            }
            if count == 0 { try await scope.finish() }
            else { await #expect(throws: SQLiteFixtureScope.FixtureError.sqliteFailures) { try await scope.finish() } }
        }
        #expect(scope.trace.contains { $0["stage"] == "root-removed" })
        #expect(scope.trace.filter { $0["stage"] == "sqlite-failure" }.count == count)
        #expect(!scope.trace.contains { $0["stage"] == "expected-sqlite-failure" })
    }
    @Test func exactAsyncFaultPreservesBodyErrorAndClosesBeforeUnlink() async throws {
        let scope = SQLiteFixtureScope(test: "async-body-error")
        let url = try root(scope).appendingPathComponent("knowledge.sqlite")
        try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
            try setup(url)
            await #expect(throws: BodyError.sentinel) {
                try await scope.expectingFailureOnNewConnection(at: url, phase: .prepare, operation: .create, result: 1, extended: 1) {
                    try fault(url); throw BodyError.sentinel
                }
            }
            try await scope.finish()
        }
        #expect(scope.trace.filter { $0["stage"] == "expected-sqlite-failure" }.count == 1)
        #expect(scope.trace.filter { $0["stage"] == "closed" && $0["result"] == "0" }.count == 2)
    }
    @Test func foreignAsyncFaultCannotBeConsumedByExpectedConnection() async throws {
        let scope = SQLiteFixtureScope(test: "async-foreign-fault")
        let root = try root(scope), url = root.appendingPathComponent("knowledge.sqlite"), foreign = root.appendingPathComponent("foreign.sqlite")
        try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
            try setup(url); try setup(foreign)
            try await rejected {
                try await scope.expectingFailureOnNewConnection(at: url, phase: .prepare, operation: .create, result: 1, extended: 1) {
                    // Open the expected connection but fail on a different one.
                    let expected = try ProjectDatabase(url: url)
                    try fault(foreign)
                    #expect(try expected.rows("SELECT COUNT(*) FROM sentinel") == [["0"]])
                }
            }
            await #expect(throws: SQLiteFixtureScope.FixtureError.sqliteFailures) { try await scope.finish() }
        }
        #expect(!scope.trace.contains { $0["stage"] == "expected-sqlite-failure" })
    }
    @Test(arguments: ["same", "foreign", "late"]) func otherNativeFaultsRemainTeardownErrors(kind: String) async throws {
        let scope = SQLiteFixtureScope(test: "async-extra-late-fault")
        let root = try root(scope), url = root.appendingPathComponent("knowledge.sqlite"), foreign = root.appendingPathComponent("foreign.sqlite")
        try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
            try setup(url); try setup(foreign)
            let operation: () async throws -> Void = {
                try await scope.expectingFailureOnNewConnection(at: url, phase: .prepare, operation: .create, result: 1, extended: 1) {
                    let db = try ProjectDatabase(url: url)
                    #expect(throws: ProjectStoreError.self) { try db.execute("CREATE TABLE sentinel(value TEXT)") }
                    if kind == "same" {
                        #expect(throws: ProjectStoreError.self) { try db.execute("CREATE TABLE sentinel(value TEXT)") }
                    }
                    if kind == "foreign" { try fault(foreign) }
                }
            }
            if kind == "same" { try await rejected(operation) }
            else { try await operation() }
            if kind == "late" { try fault(url) }
            await #expect(throws: SQLiteFixtureScope.FixtureError.sqliteFailures) { try await scope.finish() }
        }
        #expect(scope.trace.filter { $0["stage"] == "sqlite-failure" }.count == 2)
        #expect(scope.trace.filter { $0["stage"] == "expected-sqlite-failure" }.count == (kind == "same" ? 0 : 1))
    }
    @Test(arguments: [false, true]) func nestedAsyncExpectationsRequireSeparateNewConnectionsAndFaults(outerFault: Bool) async throws {
        let scope = SQLiteFixtureScope(test: "async-nested-fault")
        let url = try root(scope).appendingPathComponent("knowledge.sqlite")
        try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
            try setup(url)
            let operation: () async throws -> Void = {
                try await scope.expectingFailureOnNewConnection(at: url, phase: .prepare, operation: .create, result: 1, extended: 1) {
                    try await scope.expectingFailureOnNewConnection(at: url, phase: .prepare, operation: .create, result: 1, extended: 1) { try fault(url) }
                    if outerFault { try fault(url) }
                }
            }
            if outerFault { try await operation() }
            else { try await rejected(operation) }
            try await scope.finish()
        }
        #expect(scope.trace.filter { $0["stage"] == "sqlite-failure" }.count == (outerFault ? 2 : 1))
        #expect(scope.trace.filter { $0["stage"] == "expected-sqlite-failure" }.count == (outerFault ? 2 : 1))
    }
}
