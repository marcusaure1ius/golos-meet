import Foundation
import Testing
@testable import golos_meet

@MainActor @Suite(SQLiteFixtureTrait()) struct MemoryBridgeDiagnosticsTests {
    @Test func pausedStartupSeparatesRevisionFromStartAndExecutesFailureRecorderBeforeRecovery() async throws {
        try await MemoryBridgeTestSession.run("controlled-startup-pause") { session in
            let gate = session.gate, trace = session.trace
            session.bridge?.diagnosticBeforeStart = { configuration in
                trace.mark("control.startup.paused", ["configurationID": configuration.uuidString])
                await gate.wait()
                trace.mark("control.startup.released", ["configurationID": configuration.uuidString])
            }
            session.start()
            try await session.wait("control startup gate") { session.trace.has("control.startup.paused") }
            let before = session.fixture.worker.diagnosticSnapshot()
            #expect(before["revision"] == "1" && before["started"] == "false" && before["runID"] == "")
            #expect(!session.trace.has("configuration.start.return", owner: session.bridgeID))
            try await session.readySource()
            try await session.wait("control source discovered") {
                try await session.fixture.base.store.memoryQueueSnapshot().jobs.first?.state == .queued
            }
            #expect(session.fixture.base.spy.calls == 0 && session.physical.entered == 0)
            do {
                // An explicitly held startup cannot complete. Exercise exactly
                // the real 5s recorder/throw path, not a fabricated report.
                try await session.wait("ready-source coverage", controlled: true) { try await session.completed() }
                Issue.record("Held startup unexpectedly completed")
            } catch MemoryQueueError.busy {}
            let report = try #require(session.lastFailure)
            #expect(report.beforeUnwind && !report.atomic && report.elapsed >= 5)
            #expect(report.caseID == session.trace.id && report.bridgeID == session.bridgeID)
            #expect(report.workerID == session.fixture.worker.diagnosticOwnerID && report.transportID == session.physical.id)
            #expect(report.phase == "ready-source coverage" && report.timelineDropped == 0)
            #expect(report.timeline.filter { $0.event.stage == "condition.read.begin" }.count == report.timeline.filter { $0.event.stage == "condition.read.return" }.count)
            #expect(report.reads.allSatisfy { $0.begin <= $0.end })
            let bridge = try #require(report.reads.first { $0.name == "bridge.weak/configuration" })
            let worker = try #require(report.reads.first { $0.name == "worker.run/attempt/lease" })
            let physical = try #require(report.reads.first { $0.name == "physical.enter/return" })
            let durable = try #require(report.reads.first { $0.name == "durable.sql" })
            #expect(bridge.fields["weakAlive"] == "true" && bridge.fields["startReturnedConfigurationID"] == "")
            #expect(bridge.fields["configurationID"]?.isEmpty == false)
            #expect(worker.fields["started"] == "false" && worker.fields["workerID"] == report.workerID.uuidString)
            #expect(physical.fields["entered"] == "0" && physical.fields["returned"] == "0" && physical.fields["fakeCalls"] == "0")
            #expect(durable.rows.count == 1 && durable.rows.first?["state"] == "queued")
            #expect(report.timeline.contains { $0.event.stage == "event.received" && $0.event.ownerID == session.bridgeID })
            #expect(report.timeline.contains { $0.event.stage == "discovery.return" && $0.event.ownerID == report.workerID })
            #expect(!report.timeline.contains { $0.event.stage == "lease.claimed" || $0.event.stage == "physical.enter" })
            await gate.signal()
            try await session.wait("startup return acknowledgement") {
                session.trace.has("configuration.start.return", owner: session.bridgeID)
            }
            try await session.wait("recovered ready-source coverage") { try await session.completed() }
            #expect(session.fixture.base.spy.calls == 1 && session.physical.entered == 1 && session.physical.returned == 1)
            // Durable coverage can be read before the service caller resumes.
            // Observe its separate return explicitly; do not cancel it via
            // cleanup and do not treat a missing immediate event as data loss.
            try await session.wait("publication return acknowledgement") {
                session.trace.has("publication.inserted.return", owner: report.workerID)
            }
            #expect(session.trace.has("publication.inserted.return", owner: report.workerID))
            let lease = try #require(session.trace.rows.first { $0.event.stage == "lease.claimed" })
            let call = try #require(session.trace.rows.first { $0.event.stage == "physical.enter" })
            #expect(lease.event.fields["runID"] == call.event.fields["runID"])
            #expect(lease.event.fields["attemptID"] == call.event.fields["attemptID"])
            #expect(call.event.fields["workerID"] == report.workerID.uuidString)
        }
    }

    @Test func releasingSoleOwnerIsAttributedToCreatingObserverAndDirectRestartRecovers() async throws {
        try await MemoryBridgeTestSession.run("controlled-owner-release") { session in
            session.start()
            try await session.wait("startup return acknowledgement") {
                session.trace.has("configuration.start.return", owner: session.bridgeID)
            }
            await session.fixture.worker.waitUntilIdle()
            let oldRun = session.fixture.worker.diagnosticSnapshot()["runID"]
            let foreign = MemoryBridgeTestTrace("foreign-context")
            try await MemoryQueueDiagnostics.$observer.withValue(foreign.observe) {
                session.bridge = nil
                try await session.wait("sole owner released") { session.weakBridge == nil }
                try await session.wait("owner deinit stop returned") {
                    session.trace.has("deinit.stop.return", owner: session.bridgeID)
                }
            }
            #expect(foreign.rows.isEmpty)
            #expect(session.trace.has("deinit", owner: session.bridgeID))
            #expect(session.fixture.worker.diagnosticSnapshot()["started"] == "false")
            try await session.readySource()
            #expect(!session.trace.has("event.received", owner: session.bridgeID))
            #expect(session.physical.entered == 0 && session.fixture.base.spy.calls == 0)
            #expect(try await session.fixture.base.store.memoryQueueSnapshot().jobs.isEmpty)
            session.trace.mark("control.direct.restart", ["workerID": session.fixture.worker.diagnosticOwnerID.uuidString])
            await session.fixture.worker.start()
            try await session.wait("direct restart coverage") { try await session.completed() }
            #expect(session.fixture.worker.diagnosticSnapshot()["runID"] != oldRun)
            #expect(session.fixture.base.spy.calls == 1 && session.physical.maxPhysical == 1)
        }
    }
}

private enum BridgeControlBodyError: Error, Equatable { case intentional }

@MainActor extension MemoryBridgeDiagnosticsTests {
    @Test(arguments: [false, true])
    func strongOwnerAndGateAreReleasedWhenBodyThrowsOrCancels(cancel: Bool) async throws {
        weak var observed: KnowledgeMemoryQueue?
        let body = Task { @MainActor in
            try await MemoryBridgeTestSession.run("controlled-body-exit-\(cancel)") { session in
                observed = session.weakBridge
                let trace = session.trace, gate = session.gate
                session.bridge?.diagnosticBeforeStart = { _ in
                    trace.mark("control.exit.paused"); await gate.wait()
                }
                session.start()
                try await session.wait("controlled body exit startup gate") { trace.has("control.exit.paused") }
                if cancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
                throw BridgeControlBodyError.intentional
            }
        }
        let outcome = await body.result
        if cancel {
            #expect(body.isCancelled)
            if case .failure(let error) = outcome { #expect(error is CancellationError) }
            else { Issue.record("Cancellation control unexpectedly succeeded") }
        } else {
            #expect(throws: BridgeControlBodyError.intentional) { try outcome.get() }
        }
        #expect(observed == nil)
    }
}
