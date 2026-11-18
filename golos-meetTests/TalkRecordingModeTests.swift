import Foundation
import Testing
@testable import golos_meet

@MainActor private final class RuntimeMode: TalkRecordingModeStoring {
    var enabled = false
    var fail = false
    func load() throws -> Bool { if fail { throw URLError(.cannotOpenFile) }; return enabled }
    func save(_ value: Bool) throws { if fail { throw URLError(.cannotWriteToFile) }; enabled = value }
}
@MainActor private final class RuntimeCredential: TalkCredentialStoring {
    var credential: TalkCredential?
    var loads = 0
    var fail = false
    init(_ value: TalkCredential? = nil) { credential = value }
    func load() throws -> TalkCredential? { loads += 1; if fail { throw URLError(.cannotOpenFile) }; return credential }
    func save(_ value: TalkCredential?) throws { credential = value }
}
@MainActor private final class RuntimePreferences: TalkPreferencesStoring {
    var value: TalkMeetingPreferences?
    func load() throws -> TalkMeetingPreferences? { value }
    func save(_ value: TalkMeetingPreferences?) throws { self.value = value }
}
private actor StaleWindowLookup {
    private var continuation: CheckedContinuation<[TalkUserAccount], Error>?
    private(set) var started = false
    func lookup() async throws -> [TalkUserAccount] { started = true; return try await withCheckedThrowingContinuation { continuation = $0 } }
    func finish(_ account: TalkUserAccount) { continuation?.resume(returning: [account]); continuation = nil }
    func fail() { continuation?.resume(throwing: URLError(.notConnectedToInternet)); continuation = nil }
}

private actor StaleLookupCounter {
    private(set) var count = 0
    func lookup(_ account: TalkUserAccount) -> [TalkUserAccount] { count += 1; return [account] }
}

@Suite @MainActor struct TalkRecordingModeTests {
    private var credential: TalkCredential { .init(server: URL(string: "https://mode.example")!, token: "talkusr.synthetic", version: UUID()) }
    @Test func enablingRequiresSavedBindingAndDoesNotCommitDrafts() {
        let mode = RuntimeMode(), preferences = RuntimePreferences(), credentials = RuntimeCredential(credential)
        let model = TalkMeetingSettingsModel(preferences: preferences, credentials: credentials, mode: mode)
        #expect(!model.setAPIEnabled(true)); #expect(!mode.enabled)
        let credential = credentials.credential!
        model.bind(credential); model.rooms = [.init(input: "alpha")]
        #expect(!model.setAPIEnabled(true))
        let account = TalkUserAccount(key: "owner", login: nil, firstname: nil, surname: nil, email: "test@example.ru")
        preferences.value = .init(schemaVersion: 1, origin: credential.server, connectionVersion: credential.version!, rooms: ["saved"], account: account)
        #expect(model.setAPIEnabled(true)); #expect(mode.enabled)
        #expect(preferences.value?.rooms == ["saved"])
        credentials.credential = nil
        model.removePreferences()
        #expect(model.apiEnabled && mode.enabled) // No hidden heuristic fallback.
        #expect(model.setAPIEnabled(false)); #expect(!mode.enabled)
    }
    @Test func runtimeNeverFallsBackAfterCredentialLossRotationOrBadModeFile() {
        let mode = RuntimeMode(), credentials = RuntimeCredential(), preferences = RuntimePreferences()
        #expect(TalkRuntimeSettings.load(mode: mode, credentials: credentials, preferences: preferences) == .legacy)
        #expect(credentials.loads == 0)
        mode.enabled = true
        #expect(TalkRuntimeSettings.load(mode: mode, credentials: credentials, preferences: preferences) == .api(nil))
        let original = credential
        credentials.credential = original
        preferences.value = .init(schemaVersion: 1, origin: original.server, connectionVersion: original.version!, rooms: ["alpha"],
                                  account: .init(key: "owner", login: nil, firstname: nil, surname: nil, email: nil))
        if case .api(.some) = TalkRuntimeSettings.load(mode: mode, credentials: credentials, preferences: preferences) {} else { Issue.record("Configured API expected") }
        credentials.credential = .init(server: original.server, token: "talkusr.rotated", version: UUID())
        #expect(TalkRuntimeSettings.load(mode: mode, credentials: credentials, preferences: preferences) == .api(nil))
        credentials.credential = nil
        #expect(TalkRuntimeSettings.load(mode: mode, credentials: credentials, preferences: preferences) == .api(nil))
        mode.fail = true
        #expect(TalkRuntimeSettings.load(mode: mode, credentials: credentials, preferences: preferences) == .unavailable)
    }
    @Test func modeWriteFailureNeverClaimsChangedModeAndReportsStorageError() {
        let mode = RuntimeMode(); mode.enabled = true
        let model = TalkMeetingSettingsModel(preferences: RuntimePreferences(), credentials: RuntimeCredential(), mode: mode)
        mode.fail = true
        #expect(!model.setAPIEnabled(false))
        #expect(model.apiEnabled && mode.enabled)
        #expect(model.modeError != nil)
    }
    @Test func modeChangeRefreshesOtherOpenSettingsWithoutLosingRoomDrafts() {
        let mode = RuntimeMode(); mode.enabled = true
        let preferences = RuntimePreferences(), credentials = RuntimeCredential(credential)
        let first = TalkMeetingSettingsModel(preferences: preferences, credentials: credentials, mode: mode)
        let second = TalkMeetingSettingsModel(preferences: preferences, credentials: credentials, mode: mode)
        second.bind(credentials.credential!); second.rooms = [.init(input: "unsaved")]
        #expect(first.setAPIEnabled(false))
        #expect(!second.apiEnabled)
        #expect(second.rooms.map(\.input) == ["unsaved"])
    }
    @Test func changeDeliveryIsSynchronousAndModeFileIsTemporary() throws {
        var delivered = false
        let id = TalkSettingsChanges.observe { delivered = true }
        defer { TalkSettingsChanges.remove(id) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = TalkRecordingModeFileStore(url: root.appendingPathComponent("mode.json"))
        #expect(try !file.load()); try file.save(true); #expect(try file.load())
        let model = TalkMeetingSettingsModel(preferences: RuntimePreferences(), credentials: RuntimeCredential(), mode: file)
        #expect(model.setAPIEnabled(false)); #expect(delivered); #expect(try !file.load())
        try Data("corrupt".utf8).write(to: file.url)
        #expect(throws: (any Error).self) { try file.load() }
    }
    @Test func staleSecondWindowCannotEnableUnconfiguredAPIImmediatelyAfterPATRotation() {
        let mode = RuntimeMode(), credentials = RuntimeCredential(), preferences = RuntimePreferences()
        let original = credential
        credentials.credential = original
        preferences.value = .init(schemaVersion: 1, origin: original.server, connectionVersion: original.version!, rooms: ["oldroom"],
                                  account: .init(key: "old-owner", login: "old", firstname: nil, surname: nil, email: "old@example.ru"))
        let first = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode)
        let second = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode)
        first.newToken = "talkusr.rotated"; #expect(first.save())
        #expect(credentials.credential?.version != original.version)
        #expect(!second.meetingSettings.setAPIEnabled(true))
        #expect(!second.meetingSettings.isBound && !second.meetingSettings.isReadyForAPI)
        #expect(second.meetingSettings.confirmed == nil)
        #expect(!mode.enabled)
        #expect(TalkRuntimeSettings.load(mode: mode, credentials: credentials, preferences: preferences) == .legacy)
    }

    @Test func staleSecondWindowCannotOverwriteNewRoomsAfterPATRotation() async {
        let mode = RuntimeMode(), credentials = RuntimeCredential(), preferences = RuntimePreferences()
        let original = credential
        credentials.credential = original
        preferences.value = .init(schemaVersion: 1, origin: original.server, connectionVersion: original.version!, rooms: ["oldroom"],
                                  account: .init(key: "old-owner", login: "old", firstname: nil, surname: nil, email: "old@example.ru"))
        let first = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode)
        let second = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode)
        second.meetingSettings.rooms = [.init(input: "oldwindowdraft")]
        first.newToken = "talkusr.rotated"; #expect(first.save())
        first.meetingSettings.rooms = [.init(input: "newroom")]; #expect(first.meetingSettings.saveRooms())
        let current = preferences.value
        #expect(!second.meetingSettings.saveRooms())
        #expect(preferences.value == current)
        #expect(preferences.value?.connectionVersion == credentials.credential?.version)
    }

    @Test func lateLookupFromStaleWindowCannotReplaceNewIdentity() async {
        let mode = RuntimeMode(), credentials = RuntimeCredential(), preferences = RuntimePreferences()
        let original = credential, pending = StaleWindowLookup()
        credentials.credential = original
        let oldAccount = TalkUserAccount(key: "old-owner", login: "old", firstname: nil, surname: nil, email: "old@example.ru")
        preferences.value = .init(schemaVersion: 1, origin: original.server, connectionVersion: original.version!, rooms: ["oldroom"], account: oldAccount)
        let first = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode)
        let second = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode,
                                         lookup: { _, _ in try await pending.lookup() })
        second.meetingSettings.email = "old@example.ru"; second.meetingSettings.findAccount()
        for _ in 0..<4000 { if await pending.started { break }; await Task.yield() }
        #expect(await pending.started)
        first.newToken = "talkusr.rotated"; #expect(first.save())
        first.meetingSettings.rooms = [.init(input: "newroom")]; #expect(first.meetingSettings.saveRooms())
        let current = preferences.value
        await pending.finish(oldAccount)
        for _ in 0..<100 { await Task.yield() }
        #expect(second.meetingSettings.search == .idle)
        #expect(!second.meetingSettings.confirm(oldAccount))
        #expect(preferences.value == current)
    }

    @Test(arguments: ["confirm", "rooms", "enable", "disable", "lookup"], ["pat", "origin", "deleted", "readFailure"])
    func mutationsReadAuthoritativeCredentialEvenWithoutNotification(action: String, change: String) async {
        let mode = RuntimeMode(), credentials = RuntimeCredential(), preferences = RuntimePreferences()
        let original = credential, calls = StaleLookupCounter()
        mode.enabled = action == "disable"
        let originalMode = mode.enabled
        credentials.credential = original
        let account = TalkUserAccount(key: "owner", login: "owner", firstname: nil, surname: nil, email: "owner@example.ru")
        preferences.value = .init(schemaVersion: 1, origin: original.server, connectionVersion: original.version!, rooms: ["savedroom"], account: account)
        let model = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode, lookup: { _, _ in await calls.lookup(account) }).meetingSettings
        model.rooms = [.init(input: "oldwindowdraft")]
        model.email = "owner@example.ru"; model.findAccount()
        for _ in 0..<4000 { if case .results = model.search { break }; await Task.yield() }
        #expect(await calls.count == 1)
        switch change {
        case "pat": credentials.credential = .init(server: original.server, token: "talkusr.changed", version: UUID())
        case "origin": credentials.credential = .init(server: URL(string: "https://other.example")!, token: original.token, version: original.version)
        case "deleted": credentials.credential = nil
        default: credentials.fail = true
        }
        let saved = preferences.value
        // Deliberately no TalkSettingsChanges.post(): reactive invalidation alone
        // cannot protect a mutation or an old completed result.
        switch action {
        case "confirm": #expect(!model.confirm(account))
        case "rooms": #expect(!model.saveRooms())
        case "enable": #expect(!model.setAPIEnabled(true))
        case "disable": #expect(!model.setAPIEnabled(false))
        default:
            model.findAccount()
            for _ in 0..<50 { await Task.yield() }
            #expect(await calls.count == 1)
        }
        #expect(preferences.value == saved)
        #expect(mode.enabled == originalMode)
        #expect(!model.isBound && !model.isReadyForAPI && model.confirmed == nil)
        #expect(model.message == TalkAPIError.connectionChanged.localizedDescription)
    }

    @Test func roomSaveKeepsFreshIdentityFromOtherWindowOnSameConnection() async {
        let mode = RuntimeMode(), credentials = RuntimeCredential(credential), preferences = RuntimePreferences()
        let current = credentials.credential!
        let old = TalkUserAccount(key: "old", login: "old", firstname: nil, surname: nil, email: "old@example.ru")
        let new = TalkUserAccount(key: "new", login: "new", firstname: nil, surname: nil, email: "new@example.ru")
        preferences.value = .init(schemaVersion: 1, origin: current.server, connectionVersion: current.version!, rooms: ["savedroom"], account: old)
        let first = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode, lookup: { _, _ in [new] })
        let second = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode)
        second.meetingSettings.rooms = [.init(input: "draftroom")]
        first.meetingSettings.email = "new@example.ru"; first.meetingSettings.findAccount()
        for _ in 0..<4000 { if case .results = first.meetingSettings.search { break }; await Task.yield() }
        #expect(first.meetingSettings.confirm(new))
        #expect(second.meetingSettings.confirmed == new)
        #expect(second.meetingSettings.rooms.map(\.input) == ["draftroom"])
        #expect(second.meetingSettings.saveRooms())
        #expect(preferences.value?.account == new)
        #expect(preferences.value?.rooms == ["draftroom"])
    }

    @Test func oldConnectionWindowCannotDeleteReplacementConnection() {
        let credentials = RuntimeCredential(credential), preferences = RuntimePreferences(), mode = RuntimeMode()
        let first = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode)
        let second = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode)
        first.newToken = "talkusr.new"; #expect(first.save())
        first.meetingSettings.rooms = [.init(input: "newroom")]; #expect(first.meetingSettings.saveRooms())
        let newCredential = credentials.credential, newPreferences = preferences.value
        second.delete()
        #expect(credentials.credential == newCredential)
        #expect(preferences.value == newPreferences)
        #expect(second.diagnostic == .failed(TalkAPIError.connectionChanged.localizedDescription))
    }

    @Test(arguments: [false, true])
    func lateLookupRechecksStoreWithoutChangeEvent(replyFails: Bool) async {
        let mode = RuntimeMode(), credentials = RuntimeCredential(credential), preferences = RuntimePreferences()
        let original = credentials.credential!, pending = StaleWindowLookup()
        let old = TalkUserAccount(key: "old", login: nil, firstname: nil, surname: nil, email: "old@example.ru")
        preferences.value = .init(schemaVersion: 1, origin: original.server, connectionVersion: original.version!, rooms: ["oldroom"], account: old)
        let connection = TalkConnectionModel(store: credentials, preferences: preferences, mode: mode, lookup: { _, _ in try await pending.lookup() })
        connection.meetingSettings.email = "old@example.ru"; connection.meetingSettings.findAccount()
        for _ in 0..<4000 { if await pending.started { break }; await Task.yield() }
        #expect(await pending.started)
        let replacement = TalkCredential(server: original.server, token: "talkusr.replacement", version: UUID())
        credentials.credential = replacement
        preferences.value = .init(schemaVersion: 1, origin: replacement.server, connectionVersion: replacement.version!, rooms: ["newroom"],
                                  account: .init(key: "new", login: nil, firstname: nil, surname: nil, email: "new@example.ru"))
        let saved = preferences.value
        if replyFails { await pending.fail() } else { await pending.finish(old) }
        for _ in 0..<100 { await Task.yield() }
        #expect(connection.meetingSettings.search == .idle)
        #expect(!connection.meetingSettings.isBound && !connection.meetingSettings.isReadyForAPI)
        #expect(connection.meetingSettings.confirmed == nil)
        #expect(preferences.value == saved)
    }

}
