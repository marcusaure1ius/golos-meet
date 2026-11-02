import Foundation
import SQLite3
import Testing
@testable import golos_meet

/// One test case owns its synthetic roots until all stores and native handles
/// have gone away. No process-wide retention and no production shutdown API.
nonisolated final class SQLiteFixtureScope: @unchecked Sendable {
    @TaskLocal static var current: SQLiteFixtureScope?
    private struct WeakStore { weak var value: ProjectStore? }
    private let lock = NSLock()
    private var roots: [URL] = []
    private var stores: [WeakStore] = []
    private var connections: [UUID: URL] = [:]
    private var events: [[String: String]] = []
    private var failures: [String] = []
    private var cleanupRequests: [@Sendable () async -> Void] = []
    let id = UUID().uuidString
    init(test: String = "control") { event("scope-created", ["test": test]) }

    private func event(_ stage: String, _ fields: [String: String] = [:]) {
        events.append(fields.merging(["stage": stage, "uptime": String(ProcessInfo.processInfo.systemUptime)]) { _, new in new })
    }
    func register(root: URL) {
        lock.lock(); defer { lock.unlock() }
        precondition(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        roots.append(root); event("root-owned", ["root": root.lastPathComponent])
    }
    func register(store: ProjectStore) {
        lock.lock(); defer { lock.unlock() }
        stores.append(.init(value: store)); event("store-owned")
    }
    func observe(_ value: ProjectDatabase.LifecycleEvent) {
        lock.lock(); defer { lock.unlock() }
        switch value {
        case .opened(let connection, let url):
            connections[connection] = url
            event("opened", ["connection": connection.uuidString, "root": url.deletingLastPathComponent().lastPathComponent])
        case .closed(let connection, let result):
            event("closed", ["connection": connection.uuidString, "result": String(result)])
            if result == SQLITE_OK { connections.removeValue(forKey: connection) }
            else { failures.append("Native close returned \(result)") }
        case .failure(let diagnostic):
            // Keep the fixed-field diagnostic; it contains no SQL, values or paths.
            event("sqlite-failure", ["diagnostic": diagnostic.message])
            failures.append(diagnostic.message)
        }
    }
    func onFinish(_ cleanup: @escaping @Sendable () async -> Void) {
        lock.withLock { cleanupRequests.append(cleanup) }
    }
    func note(_ stage: String) { lock.withLock { event(stage) } }
    var trace: [[String: String]] { lock.withLock { events } }
    private func pending() -> Bool {
        // A weak load may transiently become the last strong reference. Its
        // release can close SQLite and reenter observe(), so never load it locked.
        let references = lock.withLock { stores }
        let live = references.contains { $0.value != nil }
        return live || lock.withLock { !connections.isEmpty }
    }
    func finish() async throws {
        defer { record() }
        note("body-finished")
        let requests = lock.withLock { let values = cleanupRequests; cleanupRequests = []; return values }
        for request in requests { await request() }
        let deadline = ContinuousClock.now + .seconds(8)
        while pending(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        if pending() {
            lock.withLock { event("teardown-timeout", ["openConnections": String(connections.count)]) }
            throw FixtureError.resourcesStillAlive
        }
        for root in roots {
            try FileManager.default.removeItem(at: root)
            lock.withLock { event("root-removed", ["root": root.lastPathComponent, "exists": String(FileManager.default.fileExists(atPath: root.path))]) }
        }
        let failures = lock.withLock { self.failures }
        if !failures.isEmpty { throw FixtureError.sqliteFailures }
    }
    private func record() {
        let rows = lock.withLock { events }
        if let bytes = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
            Attachment.record(bytes, named: "sqlite-fixture-\(id).json")
            if let folder = ProcessInfo.processInfo.environment["GOLOS_FIXTURE_EVIDENCE"] {
                let output = URL(fileURLWithPath: folder)
                try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try? bytes.write(to: output.appendingPathComponent(id + ".json"))
            }
        }
    }
    enum FixtureError: Error { case resourcesStillAlive, sqliteFailures }
}

nonisolated struct SQLiteFixtureTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? { testCase == nil ? nil : self }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        let scope = SQLiteFixtureScope(test: test.name)
        try await SQLiteFixtureScope.$current.withValue(scope) {
            try await ProjectDatabase.$lifecycleObserver.withValue({ scope.observe($0) }) {
                let result: Result<Void, any Error>
                do { try await function(); result = .success(()) }
                catch { result = .failure(error) }
                do { try await scope.finish() }
                catch { Issue.record(error) }
                try result.get()
            }
        }
    }
}
