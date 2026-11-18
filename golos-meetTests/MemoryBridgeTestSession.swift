import Foundation
import Testing
@testable import golos_meet

// Receipts hold one future ACK independently of the bounded evidence journal.
// The caller owns the receipt; the trace keeps at most 32 weak subscriptions.
nonisolated final class MemoryBridgeTestAck: @unchecked Sendable {
    struct Scope: Equatable, Sendable {
        let owner: UUID
        let kind: String
        let stage: String
        var fields: [String: String] = [:]
        func matches(_ event: MemoryQueueDiagnostics.Event) -> Bool {
            event.ownerID == owner && event.ownerKind == kind && event.stage == stage &&
            fields.allSatisfy { event.fields[$0.key] == $0.value }
        }
    }
    enum Failure: Error, Equatable { case obsoleteScope, consumed, subscriptionLimit, evidenceOverflow }
    let scope: Scope
    private let lock = NSLock()
    private var event: MemoryQueueDiagnostics.Event?
    private var consumed = false
    init(_ scope: Scope) { self.scope = scope }
    fileprivate func observe(_ value: MemoryQueueDiagnostics.Event) {
        lock.withLock {
            guard !consumed, event == nil, scope.matches(value) else { return }
            event = value
        }
    }
    fileprivate var isConsumed: Bool { lock.withLock { consumed } }
    func ready(for current: Scope, matching fields: [String: String] = [:]) throws -> Bool {
        try lock.withLock {
            guard current == scope else { throw Failure.obsoleteScope }
            guard !consumed else { throw Failure.consumed }
            guard let event else { return false }
            guard fields.allSatisfy({ event.fields[$0.key] == $0.value }) else { throw Failure.obsoleteScope }
            return true
        }
    }
    @discardableResult func consume(for current: Scope, matching fields: [String: String] = [:]) throws -> Bool {
        try lock.withLock {
            guard current == scope else { throw Failure.obsoleteScope }
            guard !consumed else { throw Failure.consumed }
            guard let event else { return false }
            guard fields.allSatisfy({ event.fields[$0.key] == $0.value }) else { throw Failure.obsoleteScope }
            consumed = true; self.event = nil
            return true
        }
    }
}

nonisolated final class MemoryBridgeTestTrace: @unchecked Sendable {
    struct Row: Codable, Sendable {
        let sequence: Int
        let caseID: UUID
        let event: MemoryQueueDiagnostics.Event
    }
    let id = UUID()
    let scenario: String
    private let lock = NSLock()
    private var values: [Row] = []
    private var dropped = 0
    private final class Subscription {
        weak var ack: MemoryBridgeTestAck?
        init(_ ack: MemoryBridgeTestAck) { self.ack = ack }
    }
    private var subscriptions: [Subscription] = []
    func arm(_ scope: MemoryBridgeTestAck.Scope) throws -> MemoryBridgeTestAck {
        try lock.withLock {
            subscriptions.removeAll { $0.ack == nil || $0.ack?.isConsumed == true }
            guard subscriptions.count < 32 else { throw MemoryBridgeTestAck.Failure.subscriptionLimit }
            let ack = MemoryBridgeTestAck(scope)
            subscriptions.append(Subscription(ack))
            return ack
        }
    }
    init(_ scenario: String) { self.scenario = scenario }
    func observe(_ event: MemoryQueueDiagnostics.Event) {
        lock.withLock {
            subscriptions.removeAll { $0.ack == nil || $0.ack?.isConsumed == true }
            for subscription in subscriptions { subscription.ack?.observe(event) }
            guard values.count < 4096 else { dropped += 1; return }
            values.append(.init(sequence: values.count, caseID: id, event: event))
        }
    }
    func mark(_ stage: String, _ fields: [String: String] = [:]) {
        observe(.init(ownerID: id, ownerKind: "case", stage: stage,
                      uptime: ProcessInfo.processInfo.systemUptime, fields: fields))
    }
    var rows: [Row] { lock.withLock { values } }
    var droppedCount: Int { lock.withLock { dropped } }
    // Evidence only. Missing rows after truncation are unknown, never absence.
    func evidence(_ stage: String, owner: UUID? = nil, fields: [String: String] = [:]) throws -> Bool {
        try lock.withLock {
            if values.contains(where: { row in
                row.event.stage == stage && (owner == nil || row.event.ownerID == owner) &&
                fields.allSatisfy { row.event.fields[$0.key] == $0.value }
            }) { return true }
            guard dropped == 0 else { throw MemoryBridgeTestAck.Failure.evidenceOverflow }
            return false
        }
    }
    func attach<T: Encodable>(_ value: T, suffix: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value), name = "bridge61-\(id)-\(suffix).json"
        Attachment.record(data, named: name)
        if let directory = ProcessInfo.processInfo.environment["GOLOS_BRIDGE_EVIDENCE"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(name))
        }
    }
    func attachTimeline() throws {
        struct Timeline: Encodable {
            let scenario: String
            let caseID: UUID
            let dropped: Int
            let rows: [Row]
        }
        try attach(Timeline(scenario: scenario, caseID: id, dropped: lock.withLock { dropped }, rows: rows), suffix: "timeline")
    }
}

@MainActor final class MemoryBridgePhysicalSpy: ChatCompleter {
    let id = UUID()
    let trace: MemoryBridgeTestTrace
    let wrapped: MemoryTransportSpy
    weak var worker: ProjectMemoryQueueWorker?
    private(set) var entered = 0
    private(set) var returned = 0
    private(set) var inFlight = 0
    private(set) var maxPhysical = 0
    init(_ wrapped: MemoryTransportSpy, trace: MemoryBridgeTestTrace) { self.wrapped = wrapped; self.trace = trace }
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        try await send(model: model, messages: messages, responseFormat: responseFormat, check: {})
    }
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?, beforeSending: @escaping @Sendable () async throws -> Void) async throws -> String {
        try await send(model: model, messages: messages, responseFormat: responseFormat, check: beforeSending)
    }
    private func send(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?, check: @escaping @Sendable () async throws -> Void) async throws -> String {
        let invocation = UUID()
        entered += 1; inFlight += 1; maxPhysical = max(maxPhysical, inFlight)
        var fields = worker?.diagnosticSnapshot() ?? [:]
        fields["invocationID"] = invocation.uuidString
        MemoryQueueDiagnostics.record(trace.observe, owner: id, kind: "transport", stage: "physical.enter", fields: fields)
        defer {
            returned += 1; inFlight -= 1
            MemoryQueueDiagnostics.record(trace.observe, owner: id, kind: "transport", stage: "physical.return", fields: fields)
        }
        return try await wrapped.complete(model: model, messages: messages, responseFormat: responseFormat, beforeSending: check)
    }
    func snapshot() -> [String: String] {
        ["transportID": id.uuidString, "entered": String(entered), "returned": String(returned),
         "inFlight": String(inFlight), "maxPhysical": String(maxPhysical), "fakeCalls": String(wrapped.calls)]
    }
}

extension ProjectStore {
    /// Failure-only bounded SQL read. No lease reservation or generation change.
    func bridgeDiagnosticDurableState() throws -> [[String: String]] {
        try memoryTransaction { db in
            let run = try db.rows("SELECT generation FROM memory_queue_runtime WHERE slot=1").first?.first ?? ""
            let columns = ["sequence", "projectID", "sourceKey", "generation", "attemptID", "cursor", "total", "state", "cycleID", "model"]
            return try db.rows("SELECT sequence,project_id,source_key,generation,COALESCE(attempt,''),cursor,total,state,cycle,generator_model FROM memory_queue_work ORDER BY sequence LIMIT 257").map { row in
                Dictionary(uniqueKeysWithValues: zip(columns, row)).merging(["runID": run]) { _, new in new }
            }
        }
    }
}

@MainActor final class MemoryBridgeTestSession {
    struct Read: Codable {
        let name: String
        let begin: Double
        let end: Double
        let fields: [String: String]
        let rows: [[String: String]]
    }
    struct Failure: Codable {
        let scenario: String
        let caseID: UUID
        let phase: String
        let error: String
        let elapsed: Double
        let bridgeID: UUID
        let workerID: UUID
        let transportID: UUID
        let beforeUnwind: Bool
        let atomic: Bool
        let reads: [Read]
        let timeline: [MemoryBridgeTestTrace.Row]
        let timelineDropped: Int
    }
    let fixture: QueueFixture
    let trace: MemoryBridgeTestTrace
    let physical: MemoryBridgePhysicalSpy
    let center = NotificationCenter()
    var bridge: KnowledgeMemoryQueue?
    weak var weakBridge: KnowledgeMemoryQueue?
    let bridgeID: UUID
    let gate = IndexGate()
    let began = ProcessInfo.processInfo.systemUptime
    private(set) var lastFailure: Failure?
    private var projectID: UUID?
    private(set) var startupAck: MemoryBridgeTestAck?
    let deinitAck: MemoryBridgeTestAck
    private var deinitJoined = false
    init(_ trace: MemoryBridgeTestTrace) throws {
        self.trace = trace
        var physical: MemoryBridgePhysicalSpy?
        fixture = try QueueFixture(clientFactory: { spy in
            let value = MemoryBridgePhysicalSpy(spy, trace: trace); physical = value; return value
        })
        self.physical = try #require(physical)
        self.physical.worker = fixture.worker
        bridge = KnowledgeMemoryQueue(worker: fixture.worker, center: center, model: "fake-only")
        weakBridge = bridge; bridgeID = try #require(bridge).diagnosticOwnerID
        deinitAck = try trace.arm(.init(owner: bridgeID, kind: "bridge", stage: "deinit.stop.return",
            fields: ["workerID": fixture.worker.diagnosticOwnerID.uuidString]))
        trace.mark("owners.bound", ["bridgeID": bridgeID.uuidString, "workerID": fixture.worker.diagnosticOwnerID.uuidString,
                                    "transportID": self.physical.id.uuidString])
        let worker = fixture.worker, base = fixture.base, gate = gate
        SQLiteFixtureScope.current?.onFinish { @MainActor [weak bridge, weak worker, weak base] in
            bridge?.stop(); base?.cleanup(); await gate.signal(); await worker?.stop()
        }
    }
    static func run(_ scenario: String, body: (MemoryBridgeTestSession) async throws -> Void) async throws {
        let trace = MemoryBridgeTestTrace(scenario)
        try await MemoryQueueDiagnostics.$observer.withValue(trace.observe) {
            let session = try MemoryBridgeTestSession(trace)
            do {
                session.projectID = try await session.fixture.base.project()
                try await body(session)
                await session.cleanup()
                try trace.attachTimeline()
            } catch {
                // wait() already recorded before unwinding; other errors are
                // also captured while the strong fixture/bridge are still here.
                if session.lastFailure == nil { await session.recordFailure(phase: "body", error: error) }
                await session.cleanup()
                try? trace.attachTimeline()
                throw error
            }
        }
    }
    func startupScope() throws -> MemoryBridgeTestAck.Scope {
        let state = try #require(bridge).diagnosticSnapshot()
        let configuration = try #require(state["configurationID"])
        #expect(!configuration.isEmpty)
        return .init(owner: bridgeID, kind: "bridge", stage: "configuration.start.return",
                     fields: ["workerID": fixture.worker.diagnosticOwnerID.uuidString, "configurationID": configuration])
    }
    func start() throws {
        trace.mark("test.start.request"); bridge?.start()
        // start() and arm() run synchronously on MainActor. The async native
        // startup task cannot return between them. No historical replay.
        startupAck = try trace.arm(startupScope())
    }
    func startupReturned() throws -> Bool {
        let ack = try #require(startupAck), state = try #require(bridge).diagnosticSnapshot()
        return try ack.ready(for: startupScope(), matching: ["workerRunID": state["workerRunID"] ?? ""])
    }
    func waitForStartup() async throws {
        try await wait("startup return acknowledgement") { try startupReturned() }
        let state = try #require(bridge).diagnosticSnapshot()
        #expect(try startupAck?.consume(for: startupScope(), matching: ["workerRunID": state["workerRunID"] ?? ""]) == true)
    }
    func joinDeinit() throws -> Bool {
        if deinitJoined { return true } // One lifetime, one join; never another action's permission.
        deinitJoined = try deinitAck.consume(for: deinitAck.scope)
        return deinitJoined
    }
    func readySource() async throws {
        let project = try #require(projectID)
        try await fixture.meeting("late", count: 1, owners: [project])
        trace.mark("input.ready")
        trace.mark("event.post.begin"); KnowledgeIndexEvents.post(.meeting("late"), center: center); trace.mark("event.post.end")
    }
    func completed() async throws -> Bool {
        try await fixture.base.store.memoryQueueSnapshot().jobs.first { $0.source.externalID == "late" }?.completeCoverage == true
    }
    func wait(_ phase: String, controlled: Bool = false, _ condition: () async throws -> Bool) async throws {
        // Дедлайн защищает от реально зависшего ожидания, а не ограничивает нагрузку:
        // в полном прогоне suite-тесты идут параллельно, и корректному коду может не
        // хватить 5 с (#61 — synthetic timeout воспроизводится только под нагрузкой,
        // изолированные прогоны всегда зелёные). Управляемые ожидания (controlled)
        // намеренно проверяют реальный 5-секундный путь таймаута и сохраняют бюджет.
        let end = ContinuousClock.now + (controlled ? .seconds(5) : .seconds(60))
        trace.mark("wait.begin", ["phase": phase])
        do {
            var iteration = 0
            while true {
                iteration += 1
                let reading = ["phase": phase, "iteration": String(iteration)]
                trace.mark("condition.read.begin", reading)
                let reached: Bool
                do {
                    reached = try await condition()
                    trace.mark("condition.read.return", reading)
                } catch {
                    trace.mark("condition.read.error", reading); throw error
                }
                if reached { break }
                if ContinuousClock.now > end {
                    if !controlled { Issue.record("Timed out waiting for \(phase)") }
                    throw MemoryQueueError.busy
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            trace.mark("wait.return", ["phase": phase])
        } catch {
            await recordFailure(phase: phase, error: error)
            throw error
        }
    }
    func recordFailure(phase: String, error: Error) async {
        var reads: [Read] = []
        func syncRead(_ name: String, _ body: () -> [String: String]) {
            let start = ProcessInfo.processInfo.systemUptime; trace.mark("read.begin", ["name": name])
            let fields = body(); let end = ProcessInfo.processInfo.systemUptime
            reads.append(.init(name: name, begin: start, end: end, fields: fields, rows: [])); trace.mark("read.end", ["name": name])
        }
        syncRead("bridge.weak/configuration") {
            var fields = weakBridge?.diagnosticSnapshot() ?? [:]
            fields["weakAlive"] = String(weakBridge != nil); return fields
        }
        syncRead("worker.run/attempt/lease") { fixture.worker.diagnosticSnapshot() }
        syncRead("physical.enter/return") { physical.snapshot() }
        let start = ProcessInfo.processInfo.systemUptime; trace.mark("read.begin", ["name": "durable.sql", "awaited": "true"])
        var rows: [[String: String]] = [], fields: [String: String] = [:]
        do { rows = try await fixture.base.store.bridgeDiagnosticDurableState(); fields["limited"] = String(rows.count > 256); rows = Array(rows.prefix(256)) }
        catch { fields["error"] = String(describing: error) }
        let end = ProcessInfo.processInfo.systemUptime; trace.mark("read.end", ["name": "durable.sql", "awaited": "true"])
        reads.append(.init(name: "durable.sql", begin: start, end: end, fields: fields, rows: rows))
        let report = Failure(scenario: trace.scenario, caseID: trace.id, phase: phase, error: String(describing: error),
            elapsed: ProcessInfo.processInfo.systemUptime - began, bridgeID: bridgeID,
            workerID: fixture.worker.diagnosticOwnerID, transportID: physical.id, beforeUnwind: true, atomic: false,
            reads: reads, timeline: trace.rows, timelineDropped: trace.droppedCount)
        lastFailure = report
        do { try trace.attach(report, suffix: "failure") }
        catch { Issue.record("Could not save bridge failure evidence: \(error)") }
    }
    func cleanup() async {
        bridge?.stop(); bridge = nil
        await gate.signal(); await fixture.cleanup()
        // Join the observed deinit-stop when a bridge was actually released.
        // This does not change worker/bridge production lifetime semantics.
        // Budget is load-tolerant: under a parallel suite run the stop may be
        // scheduled late without being hung (#61).
        let end = ContinuousClock.now + .seconds(60)
        do {
            while try !joinDeinit(), ContinuousClock.now < end { await Task.yield() }
            #expect(try joinDeinit())
        } catch { Issue.record("Could not join native deinit stop: \(error)") }
    }
}
