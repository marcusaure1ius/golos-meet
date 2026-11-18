import Foundation
import Testing
@testable import golos_meet

/// Cancellation-aware manual monotonic clock. No wall-time sleeps or network.
private final class RoomTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var waits: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var now: TimeInterval { lock.withLock { time } }
    var sleepers: Int { lock.withLock { waits.count } }
    var clock: TalkPollingClock {
        TalkPollingClock(now: { self.now }, sleep: { try await self.sleep($0) })
    }
    private func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()) }
                else { waits[id] = (time + delay, continuation); lock.unlock() }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.waits.removeValue(forKey: id)?.1 }
            continuation?.resume(throwing: CancellationError())
        }
    }
    func advance(_ amount: TimeInterval) {
        let ready = lock.withLock {
            time += amount
            let ids = waits.filter { $0.value.0 <= time }.map(\.key)
            return ids.compactMap { waits.removeValue(forKey: $0)?.1 }
        }
        ready.forEach { $0.resume() }
    }
}

/// Intentionally ignores cancellation, to exercise late-result generation guards.
private actor RoomReplies {
    struct Call: Sendable {
        let config: TalkRoomConfiguration
        let room: String
    }
    private(set) var calls: [Call] = []
    private var pending: [CheckedContinuation<TalkOnlineUsers, Error>] = []
    func fetch(_ config: TalkRoomConfiguration, _ room: String) async throws -> TalkOnlineUsers {
        calls.append(Call(config: config, room: room))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func reply(_ body: String = "{\"onlineUsers\":[]}") throws {
        pending.removeFirst().resume(returning: try JSONDecoder().decode(TalkOnlineUsers.self, from: Data(body.utf8)))
    }
    func fail(_ error: any Error) { pending.removeFirst().resume(throwing: error) }
    var count: Int { calls.count }
}

@Suite @MainActor struct TalkRoomObserverTests {
    private func config(rooms: [String] = ["alpha", "beta"], user: String = "owner",
                        token: String = "synthetic-pat", server: String = "https://rooms.example") throws -> TalkRoomConfiguration {
        try TalkRoomConfiguration(credential: TalkCredential(server: URL(string: server)!, token: token),
                                  rooms: rooms, userKey: user)
    }
    private func wait(_ condition: () async -> Bool) async {
        for _ in 0..<4000 {
            if await condition() { return }
            await Task.yield()
        }
        #expect(await condition(), "Асинхронная проверка не достигла ожидаемого состояния")
    }
    private func users(_ keys: [String], unique: String = "conference-session") -> String {
        let entries = keys.map { "{\"uniqueId\":\"\(unique)\",\"isAnonymous\":false,\"userInfo\":{\"key\":\"\($0)\",\"firstname\":\"Одинаковое имя\"}}" }
        return "{\"onlineUsers\":[\(entries.joined(separator: ","))]}"
    }

    @Test func canonicalizesDeduplicatesAndRejectsUnsafeRooms() throws {
        let value = try config(rooms: [" beta ", "https://ROOMS.example:443/alpha/", "alpha", "https://rooms.example/beta"])
        #expect(value.rooms == ["alpha", "beta"])
        #expect(value.credential.server.absoluteString == "https://rooms.example")
        for input in ["https://other.example/alpha", "http://rooms.example/alpha", "https://rooms.example/alpha?pat=bad",
                      "https://rooms.example/alpha#hash", "https://user@rooms.example/alpha", "https://rooms.example/%61lpha",
                      "../alpha", "Alpha", "a/b", "", "a\nb", "https://rooms.example:444/alpha"] {
            #expect(throws: (any Error).self) { try config(rooms: [input]) }
        }
        #expect(throws: TalkRoomConfigurationError.invalidRooms) { try config(rooms: []) }
        #expect(throws: TalkRoomConfigurationError.invalidRooms) { try config(rooms: (0..<11).map { "r\($0)" }) }
        #expect(throws: TalkRoomConfigurationError.invalidIdentity) { try config(user: " ") }
    }

    @Test func completeCycleMatchesKeyNotNamesOrUniqueIDAndAggregatesRooms() async throws {
        let replies = RoomReplies(), time = RoomTestClock()
        let observer = TalkRoomObserver(clock: time.clock, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config())
        observer.start(); observer.start()
        await wait { await replies.count == 1 }
        // Same display name and even conference uniqueId=owner are insufficient.
        try await replies.reply(users(["someone-else"], unique: "owner"))
        await wait { await replies.count == 2 }
        #expect(observer.observation.presence == .unknown(.checking))
        try await replies.reply(users(["owner", "someone-else"]))
        await wait { observer.observation.presence == .present(rooms: ["beta"]) }
        await wait { time.sleepers == 1 }
        time.advance(10)
        await wait { await replies.count == 3 }
        try await replies.reply(users(["owner"]))
        await wait { await replies.count == 4 }
        try await replies.reply(users(["owner"]))
        await wait { observer.observation.presence == .present(rooms: ["alpha", "beta"]) }
        observer.stop()
    }

    @Test func onlyCompleteNegativeCycleConfirmsAbsenceAndStateExpires() async throws {
        let replies = RoomReplies(), time = RoomTestClock()
        let observer = TalkRoomObserver(clock: time.clock, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config()); observer.start()
        await wait { await replies.count == 1 }
        try await replies.reply("{\"onlineUsers\":[{\"uniqueId\":\"owner\",\"isAnonymous\":true,\"anonymousId\":\"owner\"}]}")
        await wait { await replies.count == 2 }
        #expect(observer.observation.presence == .unknown(.checking))
        try await replies.reply()
        await wait { observer.observation.presence == .absent }
        await wait { time.sleepers == 1 }
        time.advance(30)
        #expect(observer.observation.presence == .unknown(.stale))
        observer.stop()
        // If the new cycle entered transport before stop, release it safely.
        await Task.yield()
        if await replies.count > 2 { try await replies.reply() }
    }

    @Test(arguments: [TalkAPIError.unauthorized, .forbidden, .rateLimited, .invalidResponse, .http(503)], [false, true])
    func partialCycleNeverSignalsExitOrPartialPositive(error: TalkAPIError, firstPresent: Bool) async throws {
        let replies = RoomReplies(), time = RoomTestClock()
        let observer = TalkRoomObserver(clock: time.clock, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config()); observer.start()
        await wait { await replies.count == 1 }
        try await replies.reply(users(firstPresent ? ["owner"] : []))
        await wait { await replies.count == 2 }
        await replies.fail(error)
        await wait { time.sleepers == 1 }
        switch observer.observation.presence { case .unknown: break; default: Issue.record("Неполный цикл выдан за достоверный") }
        #expect(observer.observation.checkedAt == nil)
        observer.stop()
    }

    @Test(arguments: ["origin", "token", "rooms", "identity"])
    func changedConfigurationDiscardsLateReplyAndDoesNotOverlap(kind: String) async throws {
        let replies = RoomReplies(), time = RoomTestClock()
        let observer = TalkRoomObserver(clock: time.clock, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config(rooms: ["alpha"])); observer.start()
        await wait { await replies.count == 1 }
        let oldGeneration = observer.observation.generation
        let next = try config(rooms: kind == "rooms" ? ["gamma"] : ["alpha"], user: kind == "identity" ? "next" : "owner",
                              token: kind == "token" ? "replacement-synthetic" : "synthetic-pat",
                              server: kind == "origin" ? "https://new.example" : "https://rooms.example")
        observer.configure(next)
        #expect(observer.observation.generation > oldGeneration)
        #expect(observer.observation.presence == .unknown(.checking))
        for _ in 0..<20 { await Task.yield() }
        #expect(await replies.count == 1) // Cancel-ignoring old request still owns slot.
        try await replies.reply(users(["owner"]))
        await wait { await replies.count == 2 }
        #expect(observer.observation.presence == .unknown(.checking))
        #expect(await replies.calls.last?.config == next)
        try await replies.reply()
        await wait { observer.observation.presence == .absent }
        observer.stop()
    }

    @Test func pauseWakeStopRestartDiscardOldReplies() async throws {
        let replies = RoomReplies(), time = RoomTestClock()
        let observer = TalkRoomObserver(clock: time.clock, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config(rooms: ["alpha"])); observer.start()
        await wait { await replies.count == 1 }
        observer.pause(); time.advance(1000)
        #expect(observer.observation.presence == .unknown(.paused))
        observer.resume()
        try await replies.reply(users(["owner"]))
        await wait { await replies.count == 2 }
        #expect(observer.observation.presence == .unknown(.checking))
        observer.stop()
        try await replies.reply(users(["owner"]))
        for _ in 0..<40 { await Task.yield() }
        #expect(observer.observation.presence == .unknown(.stopped))
        #expect(await replies.count == 2)
        observer.start()
        await wait { await replies.count == 3 }
        try await replies.reply()
        await wait { observer.observation.presence == .absent }
        observer.stop()
    }

    @Test func positiveExpiresDuringStalledCycleAndNetworkFailureIsUnknown() async throws {
        let replies = RoomReplies(), time = RoomTestClock()
        let observer = TalkRoomObserver(clock: time.clock, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config(rooms: ["alpha"])); observer.start()
        await wait { await replies.count == 1 }
        try await replies.reply(users(["owner"]))
        await wait { time.sleepers == 1 }
        #expect(observer.observation.presence == .present(rooms: ["alpha"]))
        time.advance(10)
        await wait { await replies.count == 2 }
        time.advance(20)
        #expect(observer.observation.presence == .unknown(.stale))
        await replies.fail(URLError(.notConnectedToInternet))
        await wait { observer.observation.presence == .unknown(.unavailable) }
        observer.stop()
    }

    @Test func defaultObserverCannotUseLiveTransportInTestHost() async throws {
        let observer = TalkRoomObserver()
        observer.configure(try config(rooms: ["alpha"])); observer.start()
        await wait { observer.observation.presence == .unknown(.invalidResponse) }
        observer.stop()
    }

    @Test func slowFullCycleIsUnknownAndNoTickCreatesOverlappingRequests() async throws {
        let replies = RoomReplies(), time = RoomTestClock()
        let observer = TalkRoomObserver(clock: time.clock, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config()); observer.start()
        await wait { await replies.count == 1 }
        time.advance(100)
        #expect(await replies.count == 1)
        try await replies.reply()
        await wait { await replies.count == 2 }
        try await replies.reply()
        await wait { time.sleepers == 1 }
        #expect(observer.observation.presence == .unknown(.stale))
        observer.stop()
    }
}

private final class RoomTransportProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.value(forHTTPHeaderField: "X-Auth-Token") ?? ""
        let valid = request.httpMethod == "GET" && request.url?.query == nil && request.url?.scheme == "https"
        let status = !valid ? 400 : mode.hasPrefix("limited") ? 429 : mode == "redirect" ? 302 : 200
        let body: String
        switch mode {
        case "missing": body = "{\"onlineUsers\":[{\"uniqueId\":\"s1\",\"isAnonymous\":false}]}"
        case "emptykey": body = "{\"onlineUsers\":[{\"uniqueId\":\"s1\",\"isAnonymous\":false,\"userInfo\":{\"key\":\"\"}}]}"
        case "invalid": body = "{\"private-server-text\":\"synthetic-sensitive-body\"}"
        case "anonymous": body = "{\"onlineUsers\":[{\"uniqueId\":\"s1\",\"isAnonymous\":true}]}"
        case "limited-seconds", "limited-bad", "limited-date", "redirect": body = "synthetic-sensitive-body"
        default: body = "{\"onlineUsers\":[{\"uniqueId\":\"session7\",\"isAnonymous\":false,\"userInfo\":{\"key\":\"owner\"}}]}"
        }
        var headers = ["Content-Type": "application/json"]
        if mode == "limited-seconds" { headers["Retry-After"] = "120" }
        if mode == "limited-bad" { headers["Retry-After"] = "garbage" }
        if mode == "limited-date" { headers["Retry-After"] = "Tue, 01 Jan 2030 00:00:00 GMT" }
        if mode == "redirect" { headers["Location"] = "https://other.example/stolen" }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite @MainActor struct TalkRoomTransportTests {
    private func client(_ token: String, budget: TalkRequestBudget) throws -> TalkAPIClient {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [RoomTransportProtocol.self]
        return try TalkAPIClient(server: URL(string: "https://TRANSPORT.example:443/")!, token: token,
                                 session: URLSession(configuration: session), budget: budget)
    }
    private func wait(_ condition: () async -> Bool) async {
        for _ in 0..<4000 { if await condition() { return }; await Task.yield() }
        #expect(await condition())
    }
    @Test func observerUsesRealClientWithSyntheticTransportAndSharedTime() async throws {
        let time = RoomTestClock()
        let shared = TalkRequestBudget(clock: time.clock)
        let client = try client("valid", budget: shared)
        let observer = TalkRoomObserver(clock: time.clock, fetch: { _, room in try await client.onlineUsers(room: room) })
        observer.configure(try TalkRoomConfiguration(
            credential: TalkCredential(server: URL(string: "https://transport.example")!, token: "valid"),
            rooms: ["beta", "https://transport.example/alpha", "alpha"], userKey: "owner"))
        observer.start()
        await wait { time.sleepers == 1 }
        #expect(observer.observation.presence == .unknown(.checking))
        time.advance(2)
        await wait { observer.observation.presence == .present(rooms: ["alpha", "beta"]) }
        observer.stop()
    }
    @Test func transportDecodesStableKeyAndAnonymousSeparately() async throws {
        let found = try await client("valid", budget: TalkRequestBudget()).onlineUsers(room: "alpha")
        #expect(found.onlineUsers.first?.userInfo?.key == "owner")
        #expect(found.onlineUsers.first?.uniqueId == "session7")
        let anonymous = try await client("anonymous", budget: TalkRequestBudget()).onlineUsers(room: "alpha")
        #expect(anonymous.onlineUsers.first?.isAnonymous == true)
        #expect(anonymous.onlineUsers.first?.userInfo == nil)
    }
    @Test(arguments: ["missing", "emptykey", "invalid"])
    func incompleteIdentityNeverBecomesAbsence(mode: String) async throws {
        await #expect(throws: TalkAPIError.invalidResponse) {
            _ = try await client(mode, budget: TalkRequestBudget()).onlineUsers(room: "alpha")
        }
    }
    @Test func rejectsRedirectWithoutDisplayingErrorBody() async throws {
        await #expect(throws: TalkAPIError.redirectRefused) {
            _ = try await client("redirect", budget: TalkRequestBudget()).onlineUsers(room: "alpha")
        }
        #expect(!TalkAPIError.redirectRefused.localizedDescription.contains("synthetic-sensitive-body"))
    }
    @Test(arguments: ["limited-seconds", "limited-bad", "limited-date", "limited-none"])
    func rateLimitBlocksOtherTokenAndProfileOnSameOrigin(mode: String) async throws {
        let time = RoomTestClock()
        let shared = TalkRequestBudget(clock: time.clock)
        await #expect(throws: TalkAPIError.rateLimited) {
            _ = try await client(mode, budget: shared).onlineUsers(room: "alpha")
        }
        var complete = false
        let next = Task { @MainActor in
            // Valid profile decode accepts optional fields from this fixture.
            _ = try await client("new-synthetic-token", budget: shared).profile()
            complete = true
        }
        await wait { time.sleepers == 1 }
        time.advance((mode == "limited-bad" || mode == "limited-none") ? 59 : 119)
        for _ in 0..<30 { await Task.yield() }
        #expect(!complete)
        if mode == "limited-date" {
            next.cancel()
            _ = try? await next.value
        } else {
            time.advance(1)
            try await next.value
            #expect(complete)
        }
    }
    @Test func sharedBudgetSpacesConcurrentRequestsAndCancellationHasNoBurst() async throws {
        let time = RoomTestClock(), origin = URL(string: "https://transport.example")!
        let budget = TalkRequestBudget(clock: time.clock)
        try await budget.acquire(origin: origin)
        var admitted: [TimeInterval] = []
        let a = Task { try await budget.acquire(origin: origin); admitted.append(time.now) }
        let b = Task { try await budget.acquire(origin: origin); admitted.append(time.now) }
        await wait { time.sleepers == 2 }
        time.advance(2)
        await wait { admitted.count == 1 && time.sleepers == 1 }
        #expect(admitted == [2])
        time.advance(2)
        try await a.value; try await b.value
        #expect(admitted == [2, 4])
        let cancelled = Task { try await budget.acquire(origin: origin) }
        await wait { time.sleepers == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(time.sleepers == 0)
        // A different origin has an independent account budget.
        try await budget.acquire(origin: URL(string: "https://second.example")!)
    }
}
