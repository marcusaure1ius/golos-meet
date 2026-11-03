import Foundation
import Testing
@testable import golos_meet

private final class AutomaticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var waits: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var now: TimeInterval { lock.withLock { time } }
    var sleepers: Int { lock.withLock { waits.count } }
    var clock: TalkPollingClock { .init(now: { self.now }, sleep: { try await self.sleep($0) }) }
    private func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()) }
                else { waits[id] = (time + delay, continuation); lock.unlock() }
            }
        } onCancel: { self.lock.withLock { self.waits.removeValue(forKey: id)?.1 }?.resume(throwing: CancellationError()) }
    }
    func advance(_ seconds: TimeInterval = 10) {
        let ready = lock.withLock {
            time += seconds
            return waits.filter { $0.value.0 <= time }.map(\.key).compactMap { waits.removeValue(forKey: $0)?.1 }
        }
        ready.forEach { $0.resume() }
    }
}
private actor AutomaticNative {
    var snapshot: TalkNativeSnapshot = .documents(["https://auto.example/team_room"])
    func read() -> TalkNativeSnapshot { snapshot }
    func set(_ value: TalkNativeSnapshot) { snapshot = value }
}
private actor AutomaticReplies {
    struct Call: Sendable { let credential: TalkCredential; let room: String }
    private(set) var calls: [Call] = []
    private var pending: [CheckedContinuation<TalkOnlineUsers, Error>] = []
    func fetch(_ credential: TalkCredential, _ room: String) async throws -> TalkOnlineUsers {
        calls.append(.init(credential: credential, room: room))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func reply(_ keys: [String] = []) throws {
        let users = keys.map { ["uniqueId": "conference-session", "isAnonymous": false, "userInfo": ["key": $0]] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["onlineUsers": users])
        pending.removeFirst().resume(returning: try JSONDecoder().decode(TalkOnlineUsers.self, from: data))
    }
    func fail(_ error: Error) { pending.removeFirst().resume(throwing: error) }
    var count: Int { calls.count }
}

@Suite @MainActor struct TalkAutomaticObserverTests {
    private func config(user: String = "owner", token: String = "talkusr.synthetic") throws -> TalkAutomaticConfiguration {
        try .init(credential: .init(server: URL(string: "https://auto.example")!, token: token, version: UUID()), userKey: user)
    }
    private func wait(_ check: () async -> Bool) async {
        for _ in 0..<6_000 { if await check() { return }; await Task.yield() }
        #expect(await check(), "Автоматический observer не достиг ожидаемого состояния")
    }
    private func next(_ time: AutomaticClock) async { await wait { time.sleepers > 0 }; time.advance() }

    @Test func scannerStopsAtDocumentAndNeverReadsHistoryOrChatLinks() throws {
        struct Node { var role: String; var url: String?; var children: [Node] = [] }
        let history = Node(role: "AXLink", url: "https://auto.example/not_current")
        let document = Node(role: "AXWebArea", url: "https://auto.example/", children: [history])
        var childReads = 0
        let scanner = TalkDocumentScanner<Node>(role: { $0.role }, url: { $0.url }, children: {
            #expect($0.role != "AXWebArea"); childReads += 1; return $0.children
        }, now: { 0 })
        #expect(try scanner.scan([.init(role: "AXWindow", children: [document])]) == ["https://auto.example/"])
        #expect(childReads == 1)
        let room = Node(role: "AXWebArea", url: "https://auto.example/new_room")
        #expect(try scanner.scan([room]) == ["https://auto.example/new_room"])
    }

    @Test func scannerMissingURLsIncompleteTreesAndBoundsNeverBecomeEmptySuccess() throws {
        let empty = TalkDocumentScanner<Int>(role: { _ in "AXWebArea" }, url: { _ in nil }, children: { _ in [] }, now: { 0 })
        #expect(throws: (any Error).self) { try empty.scan([0]) }
        #expect(throws: (any Error).self) { try empty.scan([]) }
        var looping = TalkDocumentScanner<Int>(role: { _ in "AXGroup" }, url: { _ in nil }, children: { [$0 + 1] }, now: { 0 })
        looping.depthLimit = 2
        #expect(throws: (any Error).self) { try looping.scan([0]) }
        var wide = looping; wide.nodeLimit = 2
        #expect(throws: (any Error).self) { try wide.scan([0, 1, 2]) }
    }

    @Test func nativeReaderIsBlockedBeforeOSAccessInTestHost() async {
        #expect(AppRuntime.isTestHost)
        #expect(await TalkNativeRoomSource().read() == .unknown(.unavailable))
    }

    @Test func extractsOnlySameOriginRoomAndDiscardsNavigationParameters() throws {
        let origin = URL(string: "https://auto.example")!
        #expect(TalkDiscoveredRoom.parse("auto.example/team_room?pin=synthetic#test", origin: origin) == "team_room")
        #expect(TalkDiscoveredRoom.parse("https://AUTO.example:443/new123/", origin: origin) == "new123")
        for value in ["https://else.example/team_room", "http://auto.example/room", "https://user:pass@auto.example/room", "https://auto.example:444/room", "https://auto.example/%72oom", "https://auto.example/a%2fb", "https://auto.example/../room", "https://auto.example/a/b", "https://auto.example/settings", "file:///tmp/preload.html"] {
            #expect(TalkDiscoveredRoom.parse(value, origin: origin) == nil)
        }
        #expect(TalkDiscoveredRoom.isNonMeetingPage("https://auto.example/", origin: origin))
        #expect(TalkDiscoveredRoom.isNonMeetingPage("https://auto.example/content/artifacts", origin: origin))
        #expect(!TalkDiscoveredRoom.isNonMeetingPage("https://else.example/", origin: origin))
    }

    @Test func prejoinMutedJoinAndLeaveMatchIdentityEvenWhenOthersRemain() async throws {
        let native = AutomaticNative(), replies = AutomaticReplies(), time = AutomaticClock()
        let observer = TalkAutomaticObserver(clock: time.clock, read: { await native.read() }, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config()); observer.start()
        await wait { await replies.count == 1 }; try await replies.reply(["other"])
        await wait { observer.observation.presence == .absent }
        await next(time); await wait { await replies.count == 2 }; try await replies.reply(["owner", "other"])
        await wait { observer.observation.presence == .present(rooms: ["team_room"]) }
        await native.set(.documents(["https://auto.example/"]))
        await next(time); await wait { await replies.count == 3 }
        #expect(await replies.calls.last?.room == "team_room")
        try await replies.reply(["other"])
        await wait { observer.observation.presence == .absent }
        await next(time); await wait { time.sleepers == 1 }
        #expect(await replies.count == 3)
        observer.stop()
    }

    @Test func unavailableAXNeverSignalsExitAndRetainedRoomIsRecheckedAfterRecovery() async throws {
        let native = AutomaticNative(), replies = AutomaticReplies(), time = AutomaticClock()
        let observer = TalkAutomaticObserver(clock: time.clock, read: { await native.read() }, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config()); observer.start()
        await wait { await replies.count == 1 }; try await replies.reply(["owner"])
        await wait { observer.observation.presence == .present(rooms: ["team_room"]) }
        await native.set(.unknown(.permissionRequired)); await next(time)
        await wait { observer.observation.nativeIssue == .permissionRequired }
        #expect(observer.observation.presence == .unknown(.unavailable))
        #expect(await replies.count == 1)
        await native.set(.documents(["https://auto.example/"])); await next(time)
        await wait { await replies.count == 2 }; await replies.fail(TalkAPIError.unauthorized)
        await wait { observer.observation.presence == .unknown(.unauthorized) }
        await next(time); await wait { await replies.count == 3 }; try await replies.reply(["owner"])
        await wait { observer.observation.presence == .present(rooms: ["team_room"]) }
        observer.stop()
    }

    @Test func partialCycleDoesNotPublishPositiveOrForgetNewRoomOnDocumentLoss() async throws {
        let native = AutomaticNative(), replies = AutomaticReplies(), time = AutomaticClock()
        await native.set(.documents(["https://auto.example/alpha", "https://auto.example/beta"]))
        let observer = TalkAutomaticObserver(clock: time.clock, read: { await native.read() }, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config()); observer.start()
        await wait { await replies.count == 1 }; try await replies.reply(["owner"])
        await wait { await replies.count == 2 }; await replies.fail(TalkAPIError.rateLimited)
        await wait { observer.observation.presence == .unknown(.rateLimited) }
        await native.set(.documents(["https://auto.example/"])); await next(time)
        await wait { await replies.count == 3 }; #expect(await replies.calls.last?.room == "alpha"); try await replies.reply()
        await wait { await replies.count == 4 }; #expect(await replies.calls.last?.room == "beta"); try await replies.reply(["owner"])
        await wait { observer.observation.presence == .present(rooms: ["beta"]) }
        observer.stop()
    }

    @Test func lateReplyCannotCrossConfigGenerationAndDoesNotOverlapRequests() async throws {
        let replies = AutomaticReplies(), time = AutomaticClock()
        let observer = TalkAutomaticObserver(clock: time.clock, read: { .documents(["https://auto.example/random_room"]) }, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config()); observer.start()
        await wait { await replies.count == 1 }
        observer.configure(try config(user: "new-owner", token: "talkusr.new"))
        #expect(await replies.count == 1)
        try await replies.reply(["owner"])
        await wait { await replies.count == 2 }
        #expect(observer.observation.presence == .unknown(.checking))
        #expect(await replies.calls.last?.credential.token == "talkusr.new")
        try await replies.reply(["new-owner"])
        await wait { observer.observation.presence == .present(rooms: ["random_room"]) }
        observer.pause(); #expect(observer.observation.presence == .unknown(.paused))
        observer.resume(); await wait { await replies.count == 3 }
        observer.stop(); try await replies.reply(["new-owner"])
        await wait { time.sleepers == 0 }
        #expect(observer.observation.presence == .unknown(.stopped))
    }

    @Test func staleResponsesAndUnrecognizedDocumentsRemainUnknown() async throws {
        let native = AutomaticNative(), replies = AutomaticReplies(), time = AutomaticClock()
        let observer = TalkAutomaticObserver(clock: time.clock, read: { await native.read() }, fetch: { try await replies.fetch($0, $1) })
        observer.configure(try config()); observer.start()
        await wait { await replies.count == 1 }; time.advance(31); try await replies.reply(["owner"])
        await wait { observer.observation.presence == .unknown(.stale) }
        await native.set(.documents(["https://auto.example/%72oom"])); await next(time)
        await wait { observer.observation.nativeIssue == .unavailable }
        #expect(await replies.count == 1)
        await native.set(.documents((0..<11).map { "https://auto.example/r\($0)" })); await next(time)
        await wait { observer.observation.nativeIssue == .limitReached }
        #expect(await replies.count == 1)
        observer.stop()
    }
}
