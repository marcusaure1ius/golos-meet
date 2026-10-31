import Foundation
import Testing
@testable import golos_meet

private final class RecordingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var waits: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var now: TimeInterval { lock.withLock { time } }
    var sleeping: Int { lock.withLock { waits.count } }
    var clock: TalkPollingClock { TalkPollingClock(now: { self.now }, sleep: { try await self.sleep($0) }) }
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
    func advance(_ delta: TimeInterval) {
        let ready = lock.withLock {
            time += delta
            return waits.filter { $0.value.0 <= time }.map(\.key).compactMap { waits.removeValue(forKey: $0)?.1 }
        }
        ready.forEach { $0.resume() }
    }
}
private actor RecordingReplies {
    private var pending: [CheckedContinuation<TalkOnlineUsers, Error>] = []
    private(set) var count = 0
    func fetch() async throws -> TalkOnlineUsers {
        count += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func reply(present: Bool = true) throws {
        let json = present ? #"{"onlineUsers":[{"uniqueId":"conference-not-user-key","isAnonymous":false,"userInfo":{"key":"owner"}}]}"# : #"{"onlineUsers":[]}"#
        pending.removeFirst().resume(returning: try JSONDecoder().decode(TalkOnlineUsers.self, from: Data(json.utf8)))
    }
    func fail(_ error: Error) { pending.removeFirst().resume(throwing: error) }
    func cancelAll() { let values = pending; pending = []; values.forEach { $0.resume(throwing: CancellationError()) } }
}
@MainActor private final class RecordingTrack: AudioTrack {
    var onFailure: (() -> Void)?
    var starts = 0
    var stops = 0
    var delayed = false
    var failing = false
    var writer: WavWriter?
    private var continuation: CheckedContinuation<Void, Never>?
    func start(into writer: WavWriter) async throws {
        starts += 1; self.writer = writer
        await writer.append(Data([0, 0, 1, 0])) // Synthetic PCM, no device.
        if delayed { await withCheckedContinuation { continuation = $0 } }
        if failing { throw URLError(.cannotOpenFile) }
    }
    func release() { continuation?.resume(); continuation = nil }
    func stop() async throws { stops += 1 }
}
@MainActor private final class RecordingBackend: SystemAudioStream {
    func startCapture() async throws {}
    func stopCapture() async throws {}
}
@MainActor private final class RecordingFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("api-rec-\(UUID())")
    let time: RecordingTestClock
    let replies = RecordingReplies()
    let mic = RecordingTrack(), sys = RecordingTrack(), state = RecordingState()
    var selection: TalkRuntimeSelection = .unavailable
    var folders: [MeetingFolder] = []
    var queued = 0
    var legacyStarts = 0
    var recorder: Recorder!
    var observer: TalkRoomObserver!
    var coordinator: AppCoordinator!
    var sourceAlive = true
    var processGuard: TalkAudioProcessGuard?

    init(realSystemTrack: Bool = false, fetch: TalkRoomObserver.Fetch? = nil, clock: RecordingTestClock = RecordingTestClock(), initialSelection: TalkRuntimeSelection? = nil) throws {
        time = clock
        selection = try initialSelection ?? .api(Self.config())
        observer = TalkRoomObserver(clock: time.clock, fetch: fetch ?? { [replies] _, _ in try await replies.fetch() })
        var system: (any AudioTrack)?
        if realSystemTrack {
            let guardValue = TalkAudioProcessGuard(targets: [.init(processID: 123, bundleIdentifier: "kontur.talk")], inspect: { [weak self] _ in self?.sourceAlive == true })
            processGuard = guardValue
            system = SystemAudioCaptureTrack(makeStream: { _, _, _ in SystemAudioCaptureSession(stream: RecordingBackend(), processGuard: guardValue) })
        }
        recorder = Recorder(enqueueProcessing: { [weak self] _, _ in self?.queued += 1 }, makeMicTrack: { [mic] in mic },
                            makeSysTrack: { [sys] in system ?? sys }, makeFolder: { [weak self] _, source in
            let id = "segment-\(self!.folders.count)"
            let folder = MeetingFolder(id: id, url: self!.root.appendingPathComponent(id), source: source)
            self!.folders.append(folder); return folder
        }, state: state)
        coordinator = AppCoordinator(dependencies: .init(recorder: recorder, state: state, observer: observer,
                                                       selection: { [weak self] in self?.selection ?? .unavailable },
                                                       now: { [time] in Date(timeIntervalSince1970: 1_000_000 + time.now) },
                                                       startLegacy: { [weak self] _ in self?.legacyStarts += 1 }))
        coordinator.start()
    }
    static func config(room: String = "alpha", token: String = "talkusr.synthetic", userKey: String = "owner") throws -> TalkRoomConfiguration {
        try TalkRoomConfiguration(credential: .init(server: URL(string: "https://recording.example")!, token: token), rooms: [room], userKey: userKey)
    }
    func meta(_ index: Int = 0) throws -> MeetingMeta {
        try MeetingMeta.decoded(Data(contentsOf: folders[index].url.appendingPathComponent("meta.json")))
    }
    func close() async {
        coordinator.prepareForTermination(); mic.release(); sys.release()
        await replies.cancelAll()
        _ = await recorder.finalizeActive(endedAt: Date(timeIntervalSince1970: 1_000_000 + time.now), preserveAudio: true)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite @MainActor struct TalkRecordingIntegrationTests {
    private func wait(_ predicate: () async -> Bool) async {
        for _ in 0..<6000 { if await predicate() { return }; await Task.yield() }
        #expect(await predicate(), "Production-coordinator сценарий не достиг ожидаемого состояния")
    }
    private func cycle(_ f: RecordingFixture, present: Bool) async throws {
        let old = await f.replies.count
        await wait { f.time.sleeping > 0 }
        f.time.advance(10)
        await wait { await f.replies.count > old }
        try await f.replies.reply(present: present)
        await wait { f.observer.observation.presence == (present ? .present(rooms: ["alpha"]) : .absent) }
        f.coordinator.pulse()
    }
    @Test func actualAPIClientURLProtocolAndMultipleRoomsProduceOneCapture() async throws {
        let clock = RecordingTestClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingAPIProtocol.self]
        let client = try TalkAPIClient(server: URL(string: "https://recording.example")!, token: "talkusr.synthetic",
                                       session: URLSession(configuration: configuration), budget: TalkRequestBudget(clock: clock.clock))
        let f = try RecordingFixture(fetch: { _, room in try await client.onlineUsers(room: room) }, clock: clock)
        f.selection = .api(try TalkRoomConfiguration(credential: .init(server: client.server, token: "talkusr.synthetic"),
                                                   rooms: ["alpha", "beta"], userKey: "owner"))
        f.coordinator.reloadConfiguration()
        await wait { clock.sleeping > 0 }; clock.advance(2)
        await wait { f.observer.observation.presence == .present(rooms: ["alpha", "beta"]) }
        f.coordinator.pulse(); await wait { f.state.phase == .recording }
        f.coordinator.update(audio: false, window: false)
        for _ in 0..<10 { f.coordinator.pulse() }
        #expect(f.folders.count == 1 && f.legacyStarts == 0)
        await f.close()
    }

    @Test func mutedJoinNeedsOnlyFreshAPIAndUnknownNeverEndsRecording() async throws {
        let f = try RecordingFixture()
        await wait { await f.replies.count == 1 }
        // No legacy monitor was started, and neither true nor false windows/input
        // callbacks can start/stop API capture.
        f.coordinator.update(audio: true, window: true)
        #expect(f.folders.isEmpty); #expect(f.legacyStarts == 0)
        try await f.replies.reply()
        await wait { f.observer.observation.presence == .present(rooms: ["alpha"]) }
        f.coordinator.update(audio: false, window: false)
        f.coordinator.pulse()
        await wait { f.state.phase == .recording }
        for _ in 0..<20 { f.coordinator.pulse(); f.coordinator.update(audio: false, window: false) }
        #expect(f.folders.count == 1); #expect(f.mic.starts == 1 && f.sys.starts == 1)
        await wait { f.time.sleeping > 0 }; f.time.advance(10)
        await wait { await f.replies.count == 2 }
        await f.replies.fail(TalkAPIError.unauthorized)
        await wait { f.observer.observation.presence == .unknown(.unauthorized) }
        f.coordinator.pulse()
        #expect(f.recorder.isRecording); #expect(f.coordinator.menuModel.detectionLine.contains("неизвестно"))
        #expect(f.coordinator.menuModel.isRecording)
        try await cycle(f, present: false)
        await wait { !f.recorder.isRecording }
        #expect(f.queued == 1)
        #expect(try Data(contentsOf: f.folders[0].url.appendingPathComponent("mic.wav")).count == 48)
        #expect(try Data(contentsOf: f.folders[0].url.appendingPathComponent("system.wav")).count == 48)
        await f.close()
    }
    @Test func manualStopSuppressesUntilAbsentThenNewPresentAndProtectsAudio() async throws {
        let f = try RecordingFixture()
        await wait { await f.replies.count == 1 }; try await f.replies.reply()
        await wait { f.observer.observation.presence == .present(rooms: ["alpha"]) }
        f.coordinator.pulse(); await wait { f.state.phase == .recording }
        f.coordinator.toggleRecording(); await wait { !f.recorder.isRecording }
        #expect(try f.meta().preserveAudio == true); #expect(f.queued == 1)
        for _ in 0..<10 { f.coordinator.pulse() }
        #expect(f.folders.count == 1)
        try await cycle(f, present: true); #expect(f.folders.count == 1)
        try await cycle(f, present: false)
        try await cycle(f, present: true)
        await wait { f.state.phase == .recording }
        #expect(f.folders.count == 2)
        await f.close()
    }
    @Test func sleepCutsProtectedSegmentAndWakeRequiresNewReply() async throws {
        let f = try RecordingFixture()
        await wait { await f.replies.count == 1 }; try await f.replies.reply()
        await wait { f.observer.observation.presence == .present(rooms: ["alpha"]) }
        f.coordinator.pulse(); await wait { f.state.phase == .recording }
        f.coordinator.willSleep(); await wait { !f.recorder.isRecording }
        #expect(try f.meta().preserveAudio == true); #expect(f.queued == 0)
        f.time.advance(3600); f.coordinator.pulse()
        #expect(f.folders.count == 1)
        f.coordinator.didWake()
        await wait { await f.replies.count == 2 }
        f.coordinator.pulse(); #expect(f.folders.count == 1)
        try await f.replies.reply()
        await wait { f.observer.observation.presence == .present(rooms: ["alpha"]) }
        f.coordinator.pulse(); await wait { f.state.phase == .recording }
        #expect(f.folders.count == 2)
        await f.close()
    }
    @Test func configChangeDiscardsLateReplyAndProtectsActiveSegment() async throws {
        let f = try RecordingFixture()
        await wait { await f.replies.count == 1 }
        let listener = TalkSettingsChanges.observe { f.coordinator.reloadConfiguration() }
        defer { TalkSettingsChanges.remove(listener) }
        f.selection = .api(try RecordingFixture.config(room: "beta", token: "talkusr.new")); TalkSettingsChanges.post()
        try await f.replies.reply() // Old generation.
        await wait { await f.replies.count == 2 }
        f.coordinator.pulse(); #expect(f.folders.isEmpty)
        try await f.replies.reply()
        await wait { f.observer.observation.presence == .present(rooms: ["beta"]) }
        f.coordinator.pulse(); await wait { f.state.phase == .recording }
        f.selection = .api(nil); f.coordinator.reloadConfiguration()
        await wait { !f.recorder.isRecording }
        #expect(try f.meta().preserveAudio == true); #expect(f.queued == 0)
        f.coordinator.update(audio: true, window: true); f.coordinator.pulse()
        #expect(f.folders.count == 1); #expect(f.legacyStarts == 0)
        await f.close()
    }
    @Test func nativeProcessLossUsesActualGuardAndNeverRestartsSameEpisode() async throws {
        let f = try RecordingFixture(realSystemTrack: true)
        await wait { await f.replies.count == 1 }; try await f.replies.reply()
        await wait { f.observer.observation.presence == .present(rooms: ["alpha"]) }
        f.coordinator.pulse(); await wait { f.state.phase == .recording }
        f.sourceAlive = false; f.processGuard?.poll()
        await wait { !f.recorder.isRecording }
        #expect(try f.meta().status == .failed); #expect(try f.meta().preserveAudio == true)
        #expect(f.queued == 0)
        f.coordinator.pulse(); #expect(f.folders.count == 1)
        await f.close()
    }
    @Test func cancellingStartWaitsForBackendAndNeverPublishesLateReady() async throws {
        let f = try RecordingFixture(); f.sys.delayed = true
        await wait { await f.replies.count == 1 }; try await f.replies.reply()
        await wait { f.observer.observation.presence == .present(rooms: ["alpha"]) }
        f.coordinator.pulse(); await wait { f.sys.starts == 1 }
        #expect(f.state.phase == .starting && f.state.live == nil)
        f.coordinator.toggleRecording(); await wait { f.sys.stops > 0 }
        f.sys.release(); await wait { !f.recorder.isRecording }
        #expect(f.state.live == nil); #expect(try f.meta().preserveAudio == true)
        f.coordinator.pulse(); #expect(f.folders.count == 1)
        await f.close()
    }
    @Test func startupFailureAllowsExplicitManualRetryAndManualIgnoresAPIExit() async throws {
        let f = try RecordingFixture(); f.sys.failing = true
        await wait { await f.replies.count == 1 }; try await f.replies.reply()
        await wait { f.observer.observation.presence == .present(rooms: ["alpha"]) }
        f.coordinator.pulse(); await wait { !f.recorder.isRecording }
        #expect(try f.meta().status == .failed)
        f.coordinator.pulse(); #expect(f.folders.count == 1)
        f.sys.failing = false; f.coordinator.toggleRecording()
        await wait { f.state.phase == .recording }
        #expect(f.state.live?.isManual == true)
        try await cycle(f, present: false)
        #expect(f.recorder.isRecording)
        await f.close()
    }
    @Test func staleCachedPresentCannotStartAndQuitBlocksAllLateActions() async throws {
        let f = try RecordingFixture()
        await wait { await f.replies.count == 1 }; try await f.replies.reply()
        await wait { f.time.sleeping > 0 }
        f.time.advance(31); f.coordinator.pulse()
        #expect(f.folders.isEmpty); #expect(f.coordinator.detectionLine.contains("устарел"))
        await wait { await f.replies.count == 2 }
        f.coordinator.prepareForTermination()
        try await f.replies.reply()
        for _ in 0..<20 { await Task.yield() }
        f.coordinator.pulse(); f.coordinator.toggleRecording(); f.coordinator.didWake(); f.coordinator.update(window: true)
        #expect(f.folders.isEmpty)
        await f.close()
    }
    @Test func normalTerminationFinalizesProtectedWAVWithoutQueue() async throws {
        let f = try RecordingFixture()
        await wait { await f.replies.count == 1 }; try await f.replies.reply()
        await wait { f.observer.observation.presence == .present(rooms: ["alpha"]) }
        f.coordinator.pulse(); await wait { f.state.phase == .recording }
        f.coordinator.prepareForTermination()
        _ = await f.recorder.finalizeActive(endedAt: Date(timeIntervalSince1970: 1_000_001), preserveAudio: true)
        #expect(try f.meta().preserveAudio == true); #expect(f.queued == 0)
        #expect(try Data(contentsOf: f.folders[0].url.appendingPathComponent("mic.wav")).count == 48)
        f.coordinator.pulse(); #expect(f.folders.count == 1)
        await f.close()
    }
    @Test func invalidInitialSettingsHaveExplicitStatusAndTerminatedCoordinatorCannotRestart() async throws {
        let f = try RecordingFixture(initialSelection: .unavailable)
        #expect(f.coordinator.detectionLine.contains("не удалось прочитать"))
        f.coordinator.prepareForTermination()
        f.selection = .api(try RecordingFixture.config()); f.coordinator.start(); f.coordinator.reloadConfiguration()
        #expect(await f.replies.count == 0)
        await f.close()
    }
    @Test func defaultCoordinatorIsBlockedBeforeRuntimeStoresInTestHost() {
        #expect(AppRuntime.isTestHost)
        #expect(TalkRuntimeSettings.production() == .unavailable)
        let coordinator = AppCoordinator(); coordinator.start()
        coordinator.update(audio: true, window: true); coordinator.pulse(); coordinator.toggleRecording()
        #expect(!coordinator.recorder.isRecording)
    }
}

private final class RecordingAPIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "recording.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let valid = request.value(forHTTPHeaderField: "X-Auth-Token") == "talkusr.synthetic" && request.url?.query == nil
            && ["/api/Rooms/alpha/online-users", "/api/Rooms/beta/online-users"].contains(request.url!.path)
        let body = #"{"onlineUsers":[{"uniqueId":"session-not-key","isAnonymous":false,"userInfo":{"key":"owner"}}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 403, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
