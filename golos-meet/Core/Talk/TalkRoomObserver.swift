import Foundation

nonisolated enum TalkRoomPresence: Equatable, Sendable {
    case present(rooms: [String]), absent, unknown(Reason)
    enum Reason: Equatable, Sendable {
        case stopped, paused, checking, stale, unavailable, unauthorized, forbidden, rateLimited, invalidResponse
    }
}
nonisolated struct TalkRoomObservation: Equatable, Sendable {
    let presence: TalkRoomPresence
    let generation: UInt64
    /// Monotonic start of a complete cycle, conservatively older than its replies.
    let checkedAt: TimeInterval?
}

/// Service only: no Recorder, windows, Keychain or OS sleep hooks. AppCoordinator
/// pauses before sleep/resumes on wake and reads `observation`,
/// whose freshness check prevents returning stale positive/negative state.
@MainActor
final class TalkRoomObserver {
    typealias Fetch = @Sendable (TalkRoomConfiguration, String) async throws -> TalkOnlineUsers
    private let clock: TalkPollingClock
    private let fetch: Fetch
    private let interval: TimeInterval
    private let freshness: TimeInterval
    private var configuration: TalkRoomConfiguration?
    private var generation: UInt64 = 0
    private var enabled = false
    private var paused = false
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var latest = TalkRoomObservation(presence: .unknown(.stopped), generation: 0, checkedAt: nil)

    var observation: TalkRoomObservation {
        if let time = latest.checkedAt, clock.now() - time >= freshness {
            return TalkRoomObservation(presence: .unknown(.stale), generation: generation, checkedAt: nil)
        }
        return latest
    }

    init(clock: TalkPollingClock = .continuous, interval: TimeInterval = 10,
         freshness: TimeInterval = 30, fetch: Fetch? = nil) {
        self.clock = clock
        self.interval = max(2, interval)
        self.freshness = max(1, freshness)
        let isTestHost = AppRuntime.isTestHost
        self.fetch = fetch ?? { config, room in
            guard !isTestHost else { throw TalkAPIError.invalidResponse }
            return try await TalkAPIClient(server: config.credential.server, token: config.credential.token).onlineUsers(room: room)
        }
    }
    deinit { worker?.cancel() }

    /// Always invalidate, even if values are equal (explicit credential reload).
    func configure(_ configuration: TalkRoomConfiguration) {
        self.configuration = configuration
        invalidate(reason: enabled ? (paused ? .paused : .checking) : .stopped)
        launchIfNeeded()
    }
    func start() {
        guard !enabled else { return }
        enabled = true
        invalidate(reason: paused ? .paused : .checking)
        launchIfNeeded()
    }
    func stop() { enabled = false; invalidate(reason: .stopped) }
    func pause() { paused = true; invalidate(reason: .paused) }
    func resume() {
        guard paused else { return }
        paused = false
        invalidate(reason: enabled ? .checking : .stopped)
        launchIfNeeded()
    }
    private func invalidate(reason: TalkRoomPresence.Reason) {
        generation &+= 1
        latest = TalkRoomObservation(presence: .unknown(reason), generation: generation, checkedAt: nil)
        worker?.cancel()
    }
    private func launchIfNeeded() {
        guard enabled, !paused, let config = configuration, worker == nil else { return }
        let current = generation, id = UUID()
        workerID = id
        let fetch = fetch, clock = clock, interval = interval, freshness = freshness
        worker = Task { [weak self] in
            while !Task.isCancelled {
                let began = clock.now()
                var present: [String] = []
                var failure: TalkRoomPresence.Reason?
                do {
                    for room in config.rooms {
                        try Task.checkCancellation()
                        let response = try await fetch(config, room)
                        try Task.checkCancellation()
                        try response.validate()
                        if response.onlineUsers.contains(where: { !$0.isAnonymous && $0.userInfo?.key == config.userKey }) {
                            present.append(room)
                        }
                    }
                } catch { failure = Self.reason(error) }
                guard !Task.isCancelled, self?.generation == current else { break }
                let state: TalkRoomPresence
                // Errors dominate even partial positives: never mix cached rooms.
                if let failure { state = .unknown(failure) }
                else if clock.now() - began >= freshness { state = .unknown(.stale) }
                else { state = present.isEmpty ? .absent : .present(rooms: present) }
                self?.latest = TalkRoomObservation(presence: state, generation: current,
                                                  checkedAt: failure == nil ? began : nil)
                do { try await clock.sleep(interval) } catch { break }
            }
            self?.finished(id)
        }
    }
    private func finished(_ id: UUID) {
        guard workerID == id else { return }
        worker = nil
        workerID = nil
        // Wait for cancellation-ignoring transports before starting a new
        // generation: one active request/cycle, no overlap or unbounded Tasks.
        launchIfNeeded()
    }
    private static func reason(_ error: Error) -> TalkRoomPresence.Reason {
        switch error as? TalkAPIError {
        case .unauthorized: .unauthorized
        case .forbidden: .forbidden
        case .rateLimited: .rateLimited
        case .invalidResponse: .invalidResponse
        default: .unavailable
        }
    }
}
