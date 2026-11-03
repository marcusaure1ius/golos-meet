import Foundation
import Combine
import os

nonisolated struct TalkAutomaticConfiguration: Equatable, Sendable {
    let credential: TalkCredential
    let userKey: String
    init(credential: TalkCredential, userKey: String) throws {
        // Reuse the identity and origin checks, without a manually entered room.
        let checked = try TalkRoomConfiguration(credential: credential, rooms: ["validation"], userKey: userKey)
        self.credential = TalkCredential(server: checked.credential.server, token: credential.token, version: credential.version)
        self.userKey = checked.userKey
    }
}

nonisolated struct TalkAutomaticObservation: Equatable, Sendable {
    var presence: TalkRoomPresence
    var nativeIssue: TalkNativeSnapshot.Issue?
    var checkedAt: TimeInterval?
    static let stopped = Self(presence: .unknown(.stopped))

    var text: String {
        switch nativeIssue {
        case .permissionRequired: return "Разрешите Golos Meet «Универсальный доступ»."
        case .unavailable: return "Окно Толка недоступно. Участие пока неизвестно."
        case .limitReached: return "Закройте лишние окна Толка или перезапустите определение встреч."
        case nil: break
        }
        switch presence {
        case .present: return "Вы во встрече."
        case .absent: return "Вы не во встрече."
        case .unknown(.stopped): return "Определение встреч выключено."
        default: return presence.statusText
        }
    }
}

/// Read-only lifecycle. No Recorder dependency; UI and menu share only status.
@MainActor final class TalkAutomaticStatus: ObservableObject {
    static let shared = TalkAutomaticStatus()
    @Published var observation = TalkAutomaticObservation.stopped
}

@MainActor final class TalkAutomaticObserver {
    typealias Read = @Sendable () async -> TalkNativeSnapshot
    typealias Fetch = @Sendable (TalkCredential, String) async throws -> TalkOnlineUsers
    private let read: Read
    private let fetch: Fetch
    private let clock: TalkPollingClock
    private let interval: TimeInterval
    private let freshness: TimeInterval
    private var configuration: TalkAutomaticConfiguration?
    private var enabled = false, paused = false
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var latest = TalkAutomaticObservation.stopped

    var observation: TalkAutomaticObservation {
        if let time = latest.checkedAt, clock.now() - time >= freshness {
            return .init(presence: .unknown(.stale))
        }
        return latest
    }

    init(clock: TalkPollingClock = .continuous, interval: TimeInterval = 10, freshness: TimeInterval = 30,
         read: Read? = nil, fetch: Fetch? = nil) {
        self.clock = clock; self.interval = max(2, interval); self.freshness = max(1, freshness)
        self.read = read ?? { await TalkNativeRoomSource().read() }
        let testHost = AppRuntime.isTestHost
        self.fetch = fetch ?? { credential, room in
            guard !testHost else { throw TalkAPIError.invalidResponse }
            return try await TalkAPIClient(server: credential.server, token: credential.token).onlineUsers(room: room)
        }
    }
    deinit { worker?.cancel() }

    func configure(_ config: TalkAutomaticConfiguration) { configuration = config; invalidate(); launch() }
    func start() { guard !enabled else { return }; enabled = true; invalidate(); launch() }
    func stop() { enabled = false; invalidate() }
    func pause() { paused = true; invalidate() }
    func resume() { guard paused else { return }; paused = false; invalidate(); launch() }
    private func invalidate() {
        generation &+= 1; worker?.cancel()
        latest = .init(presence: .unknown(!enabled ? .stopped : paused ? .paused : .checking))
    }
    private func launch() {
        guard enabled, !paused, let config = configuration, worker == nil else { return }
        let current = generation, id = UUID(), read = read, fetch = fetch, clock = clock
        let interval = interval, freshness = freshness
        workerID = id
        worker = Task { [weak self] in
            // Keep confirmed active rooms until a complete negative API cycle.
            var retained: Set<String> = []
            while !Task.isCancelled {
                let began = clock.now()
                let native = await read()
                guard !Task.isCancelled, self?.generation == current else { break }
                var next = TalkAutomaticObservation(presence: .unknown(.unavailable))
                switch native {
                case .unknown(let issue): next.nativeIssue = issue
                case .documents(let documents) where documents.isEmpty: next.nativeIssue = .unavailable
                default:
                    let documents: [String]
                    if case .documents(let values) = native { documents = values } else { documents = [] }
                    let discovered = Set(documents.compactMap { TalkDiscoveredRoom.parse($0, origin: config.credential.server) })
                    let rooms = discovered.union(retained).sorted()
                    let unreadable = documents.contains { TalkDiscoveredRoom.parse($0, origin: config.credential.server) == nil
                        && !TalkDiscoveredRoom.isNonMeetingPage($0, origin: config.credential.server) }
                    // An uncertain/partial cycle must not forget a newly seen
                    // room when its document disappears before the next retry.
                    if rooms.count <= 10 { retained.formUnion(discovered) }
                    if unreadable { next.nativeIssue = .unavailable }
                    else if rooms.count > 10 { next.nativeIssue = .limitReached }
                    else {
                        do {
                            var present: [String] = []
                            for room in rooms {
                                try Task.checkCancellation()
                                let response = try await fetch(config.credential, room)
                                try Task.checkCancellation()
                                try response.validate()
                                if response.onlineUsers.contains(where: { !$0.isAnonymous && $0.userInfo?.key == config.userKey }) { present.append(room) }
                            }
                            if clock.now() - began >= freshness { next.presence = .unknown(.stale) }
                            else {
                                next.presence = present.isEmpty ? .absent : .present(rooms: present)
                                next.checkedAt = began
                                retained = Set(present)
                            }
                        } catch {
                            switch error as? TalkAPIError {
                            case .unauthorized: next.presence = .unknown(.unauthorized)
                            case .forbidden: next.presence = .unknown(.forbidden)
                            case .rateLimited: next.presence = .unknown(.rateLimited)
                            case .invalidResponse: next.presence = .unknown(.invalidResponse)
                            default: next.presence = .unknown(.unavailable)
                            }
                        }
                    }
                }
                guard !Task.isCancelled, self?.generation == current else { break }
                if self?.latest.presence != next.presence || self?.latest.nativeIssue != next.nativeIssue {
                    let event: String
                    switch next.presence {
                    case .present: event = "present"
                    case .absent: event = "absent"
                    case .unknown: event = "unknown"
                    }
                    // Never log document URLs, room IDs, user keys or transport bodies.
                    Log.detector.info("Talk automatic observation: \(event, privacy: .public); diagnostic only")
                }
                self?.latest = next
                do { try await clock.sleep(interval) } catch { break }
            }
            guard self?.workerID == id else { return }
            self?.worker = nil; self?.workerID = nil; self?.launch()
        }
    }
}
