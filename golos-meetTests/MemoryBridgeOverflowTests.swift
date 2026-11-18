import Foundation
import Testing
@testable import golos_meet

@MainActor @Suite(SQLiteFixtureTrait()) struct MemoryBridgeOverflowTests {
    @Test func overflowPreservesNativeStartupTimeoutRecoveryAndDeinitJoin() async throws {
        try await MemoryBridgeTestSession.run("overflow-native-startup") { session in
            let trace = session.trace, gate = session.gate
            var entered = false
            session.bridge?.diagnosticBeforeStart = { _ in entered = true; await gate.wait() }
            for _ in 0..<4100 { trace.mark("overflow.fill") }
            try session.start()
            try await session.wait("overflow startup held") { entered }
            #expect(try !session.startupReturned())
            do {
                try await session.wait("overflow held ACK", controlled: true) { try session.startupReturned() }
                Issue.record("Held startup unexpectedly acknowledged")
            } catch MemoryQueueError.busy {}
            let failure = try #require(session.lastFailure)
            #expect(failure.phase == "overflow held ACK" && failure.elapsed >= 5)
            #expect(failure.beforeUnwind && failure.timelineDropped > 0 && failure.timeline.count == 4096)
            await gate.signal()
            // Independent producer state proves native start returned. Receipt
            // delivery is then checked separately despite the saturated log.
            try await session.wait("independent native startup state") {
                let state = session.bridge?.diagnosticSnapshot() ?? [:]
                return state["configurationID"]?.isEmpty == false &&
                    state["startReturnedConfigurationID"] == state["configurationID"] && state["workerStarted"] == "true"
            }
            try await session.waitForStartup()
            #expect(trace.rows.count == 4096 && trace.droppedCount > 0)
            #expect(throws: MemoryBridgeTestAck.Failure.evidenceOverflow) {
                try trace.evidence("configuration.start.return", owner: session.bridgeID)
            }
            session.bridge?.stop(); session.bridge = nil
            try await session.wait("overflow native deinit join") { try session.joinDeinit() }
            #expect(session.weakBridge == nil)
            // run() still performs the fixture stop/native close before unlink.
        }
    }

    @Test func oldConfigurationReceiptCannotAcknowledgeNewNativeStartup() async throws {
        try await MemoryBridgeTestSession.run("native-new-configuration") { session in
            try session.start()
            try await session.waitForStartup()
            let old = try #require(session.startupAck), oldScope = old.scope
            session.bridge?.stop()
            let gate = session.gate
            var entered = false
            session.bridge?.diagnosticBeforeStart = { _ in entered = true; await gate.wait() }
            try session.start()
            try await session.wait("second configuration held") { entered }
            let current = try session.startupScope()
            #expect(current != oldScope)
            #expect(throws: MemoryBridgeTestAck.Failure.obsoleteScope) { try old.ready(for: current) }
            #expect(try !session.startupReturned())
            await gate.signal()
            try await session.waitForStartup()
        }
    }

    @Test func boundedReceiptsRejectForeignOwnerKindRunAttemptAndReplay() throws {
        let trace = MemoryBridgeTestTrace("scoped-receipts")
        let scope = MemoryBridgeTestAck.Scope(owner: UUID(), kind: "worker", stage: "attempt.return",
            fields: ["configurationID": UUID().uuidString, "runID": UUID().uuidString, "attemptID": UUID().uuidString])
        let ack = try trace.arm(scope)
        for _ in 0..<4100 { trace.mark("overflow.fill") }
        func deliver(owner: UUID? = nil, kind: String? = nil, fields: [String: String]? = nil) {
            trace.observe(.init(ownerID: owner ?? scope.owner, ownerKind: kind ?? scope.kind, stage: scope.stage,
                uptime: ProcessInfo.processInfo.systemUptime, fields: fields ?? scope.fields))
        }
        deliver(owner: UUID()); deliver(kind: "bridge")
        for key in ["configurationID", "runID", "attemptID"] {
            var foreign = scope.fields; foreign[key] = UUID().uuidString; deliver(fields: foreign)
        }
        #expect(try !ack.ready(for: scope))
        deliver()
        #expect(try ack.ready(for: scope))
        var next = scope; next.fields["runID"] = UUID().uuidString
        #expect(throws: MemoryBridgeTestAck.Failure.obsoleteScope) { try ack.ready(for: next) }
        #expect(throws: MemoryBridgeTestAck.Failure.obsoleteScope) { try ack.ready(for: scope, matching: ["attemptID": UUID().uuidString]) }
        #expect(try ack.consume(for: scope))
        #expect(throws: MemoryBridgeTestAck.Failure.consumed) { try ack.ready(for: scope) }
        let fresh = try trace.arm(scope)
        #expect(try !fresh.ready(for: scope)) // No historical replay after arming.
        #expect(trace.rows.count == 4096 && trace.droppedCount > 0)

        var pending = [fresh]
        for _ in 1..<32 { pending.append(try trace.arm(scope)) }
        #expect(throws: MemoryBridgeTestAck.Failure.subscriptionLimit) { try trace.arm(scope) }
        pending.removeAll() // Weak subscriptions release abandoned waits.
        // fresh is still owned: 31 slots become available, not an eternal log.
        for _ in 1..<32 { pending.append(try trace.arm(scope)) }
        #expect(pending.count == 31)
    }
}
