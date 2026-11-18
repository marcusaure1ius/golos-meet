import Foundation

/// Monotonic time includes system sleep. Tests inject time without real sleeps.
nonisolated struct TalkPollingClock: Sendable {
    let now: @Sendable () -> TimeInterval
    let sleep: @Sendable (TimeInterval) async throws -> Void
    static let continuous: TalkPollingClock = {
        let clock = ContinuousClock(), epoch = ContinuousClock.now
        return TalkPollingClock(now: {
            let value = epoch.duration(to: clock.now).components
            return Double(value.seconds) + Double(value.attoseconds) / 1e18
        }, sleep: { seconds in try await clock.sleep(for: .seconds(max(0, seconds))) })
    }()
}

/// All default PAT clients (including profile) share this budget. Origin scoping
/// is stricter than account scoping: rotating a token cannot reset the budget.
/// Other programs using the same account remain outside our control.
actor TalkRequestBudget {
    static let shared = TalkRequestBudget()
    private let clock: TalkPollingClock
    private var next: [URL: TimeInterval] = [:]
    init(clock: TalkPollingClock = .continuous) { self.clock = clock }

    func acquire(origin: URL) async throws {
        while true {
            try Task.checkCancellation()
            let now = clock.now()
            let delay = (next[origin] ?? now) - now
            if delay > 0 { try await clock.sleep(delay); continue }
            next[origin] = now + 2 // <= 30 requests/minute, no startup burst
            return
        }
    }

    func rateLimited(origin: URL, retryAfter: TimeInterval?) {
        // PAT does not promise Retry-After. Fall back to a minute; honor any
        // longer valid server delay, including the HTTP-date form.
        let delay = retryAfter.flatMap { $0.isFinite ? max(60, $0) : nil } ?? 60
        next[origin] = max(next[origin] ?? 0, clock.now() + delay)
    }
}
