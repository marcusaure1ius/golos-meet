import Foundation
import Testing
@testable import golos_meet

@MainActor private final class SettingsCredentials: TalkCredentialStoring {
    var value: TalkCredential?
    init(_ value: TalkCredential?) { self.value = value }
    func load() throws -> TalkCredential? { value }
    func save(_ credential: TalkCredential?) throws { value = credential }
}
@MainActor private final class SettingsPreferences: TalkPreferencesStoring {
    var value: TalkMeetingPreferences?
    var fail = false
    func load() throws -> TalkMeetingPreferences? { if fail { throw URLError(.cannotOpenFile) }; return value }
    func save(_ value: TalkMeetingPreferences?) throws { if fail { throw URLError(.cannotWriteToFile) }; self.value = value }
}
private actor SettingsLookup {
    private var continuations: [CheckedContinuation<[TalkUserAccount], Error>] = []
    private(set) var count = 0
    func lookup() async throws -> [TalkUserAccount] {
        count += 1
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func reply(_ users: [TalkUserAccount]) { continuations.removeFirst().resume(returning: users) }
}

@Suite @MainActor struct TalkMeetingSettingsTests {
    private var credential: TalkCredential { TalkCredential(server: URL(string: "https://settings.example")!, token: "talkusr.synthetic", version: UUID()) }
    private var account: TalkUserAccount { TalkUserAccount(key: "owner-key", login: "owner", firstname: "Тест", surname: "Пользователь", email: "me@example.ru") }
    private func wait(_ predicate: () async -> Bool) async {
        for _ in 0..<4000 { if await predicate() { return }; await Task.yield() }
        #expect(await predicate())
    }
    @Test func normalizesPersistsEditsDeletesAndReopensWithoutSecret() throws {
        let store = SettingsPreferences(), credential = credential
        let model = TalkMeetingSettingsModel(preferences: store, credentials: SettingsCredentials(credential))
        model.bind(credential)
        model.rooms = [.init(input: " beta "), .init(input: "https://SETTINGS.example:443/alpha/"), .init(input: "alpha")]
        #expect(model.saveRooms())
        #expect(model.rooms.map(\.input) == ["alpha", "beta"])
        #expect(store.value?.rooms == ["alpha", "beta"])
        let data = try JSONEncoder().encode(store.value)
        #expect(!String(decoding: data, as: UTF8.self).contains(credential.token))
        model.rooms[0].input = "edited"
        model.removeRoom(model.rooms[1].id)
        #expect(model.saveRooms())
        let reopened = TalkMeetingSettingsModel(preferences: store, credentials: SettingsCredentials(credential))
        reopened.bind(credential)
        #expect(reopened.rooms.map(\.input) == ["edited"])
        reopened.rooms = []; #expect(reopened.saveRooms())
        #expect(store.value?.rooms == [])
    }
    @Test func invalidElementNeverPartiallySavesAndFileFailureIsVisible() {
        let credential = credential
        let store = SettingsPreferences(), model = TalkMeetingSettingsModel(preferences: SettingsPreferences(), credentials: SettingsCredentials(credential))
        model.bind(credential)
        model.rooms = [.init(input: "valid"), .init(input: "https://other.example/room")]
        #expect(model.roomError(model.rooms[1].input) != nil)
        #expect(!model.saveRooms())
        let failing = TalkMeetingSettingsModel(preferences: store, credentials: SettingsCredentials(credential))
        failing.bind(credential); failing.rooms = [.init(input: "valid")]
        store.fail = true
        #expect(!failing.saveRooms()); #expect(failing.message != nil)
        #expect(store.value == nil)
    }
    @Test func lookupRequiresExplicitSelectionAndDoesNotCommitUnsavedRooms() async throws {
        let store = SettingsPreferences(), credential = credential, account = account
        let model = TalkMeetingSettingsModel(preferences: store, credentials: SettingsCredentials(credential), lookup: { _, email in
            #expect(email == "me@example.ru")
            return [account, TalkUserAccount(key: "other", login: "other", firstname: "Тест", surname: "Пользователь", email: "other@example.ru")]
        })
        model.bind(credential); model.rooms = [.init(input: "saved")]; #expect(model.saveRooms())
        model.rooms[0].input = "unsaved"
        model.email = " me@example.ru "; model.findAccount()
        await wait { if case .results = model.search { return true }; return false }
        #expect(model.confirmed == nil)
        #expect(model.confirm(account))
        #expect(store.value?.account?.key == "owner-key")
        #expect(store.value?.rooms == ["saved"])
        let reopened = TalkMeetingSettingsModel(preferences: store, credentials: SettingsCredentials(credential))
        reopened.bind(credential)
        #expect(reopened.confirmed == account)
        #expect(reopened.rooms.map(\.input) == ["saved"])
    }
    @Test(arguments: ["email", "cancel", "origin", "pat", "delete"])
    func lateResultCannotRestoreInvalidatedSelection(change: String) async {
        let pending = SettingsLookup(), credential = credential, account = account
        let prefs = SettingsPreferences(), credentials = SettingsCredentials(credential)
        let connection = TalkConnectionModel(store: credentials, preferences: prefs, lookup: { _, _ in try await pending.lookup() })
        let model = connection.meetingSettings
        model.email = "me@example.ru"; model.findAccount()
        await wait { await pending.count == 1 }
        switch change {
        case "email": model.email = "new@example.ru"
        case "cancel": model.cancelSearch()
        case "origin": connection.serverAddress = "https://other.example"
        case "pat": connection.newToken = "talkusr.replacement"
        default: connection.delete()
        }
        await pending.reply([account])
        for _ in 0..<50 { await Task.yield() }
        #expect(model.search == .idle); #expect(model.confirmed == nil)
        #expect(!model.confirm(account)); #expect(prefs.value == nil)
    }
    @Test func savingNewPATOrOriginNeverReusesOldIdentityAndUnchangedSaveKeepsBinding() async {
        let credential = credential, account = account, prefs = SettingsPreferences()
        let credentials = SettingsCredentials(credential)
        prefs.value = TalkMeetingPreferences(schemaVersion: 1, origin: credential.server, connectionVersion: credential.version!, rooms: ["alpha"], account: account)
        let connection = TalkConnectionModel(store: credentials, preferences: prefs)
        #expect(connection.meetingSettings.confirmed == account)
        connection.serverAddress = connection.serverAddress
        connection.newToken = ""
        #expect(connection.meetingSettings.confirmed == account)
        #expect(connection.save())
        #expect(credentials.value?.version == credential.version)
        #expect(connection.meetingSettings.confirmed == account)
        connection.newToken = "talkusr.replacement"
        #expect(connection.meetingSettings.confirmed == nil)
        #expect(connection.save())
        #expect(credentials.value?.version != credential.version)
        #expect(connection.meetingSettings.confirmed == nil)
        #expect(connection.meetingSettings.rooms.isEmpty)
        connection.serverAddress = "https://other.example"
        #expect(!connection.save()) // A saved secret never follows a new origin.
        connection.newToken = "talkusr.other"
        #expect(connection.save())
        #expect(connection.meetingSettings.confirmed == nil)
        connection.delete()
        #expect(credentials.value == nil); #expect(prefs.value == nil)
        #expect(connection.newToken.isEmpty)
    }
    @Test func legacyCredentialNeedsExplicitSaveBeforeIdentitySetup() throws {
        let legacy = try JSONDecoder().decode(TalkCredential.self, from: Data(#"{"server":"https://settings.example","token":"talkusr.synthetic"}"#.utf8))
        let connection = TalkConnectionModel(store: SettingsCredentials(legacy), preferences: SettingsPreferences())
        #expect(!connection.meetingSettings.isBound)
        #expect(connection.save())
        #expect(connection.meetingSettings.isBound)
    }
    @Test func noKeyEmptyFailureAndUnlistedConfirmationAreSafe() async {
        let account = account, prefs = SettingsPreferences(), credential = credential
        let model = TalkMeetingSettingsModel(preferences: prefs, credentials: SettingsCredentials(credential), lookup: { _, _ in [] })
        model.email = "me@example.ru"; model.findAccount()
        if case .failed = model.search {} else { Issue.record("Нет ключа") }
        model.bind(credential); model.email = "invalid"; model.findAccount()
        #expect(model.search == .failed(TalkAPIError.invalidEmail.localizedDescription))
        model.email = "me@example.ru"; model.findAccount()
        await wait { model.search == .results([]) }
        #expect(!model.confirm(account))
        let failure = TalkMeetingSettingsModel(preferences: prefs, credentials: SettingsCredentials(credential), lookup: { _, _ in
            throw NSError(domain: "synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-body talkusr.synthetic"])
        })
        failure.bind(credential); failure.email = "me@example.ru"; failure.findAccount()
        await wait { if case .failed = failure.search { return true }; return false }
        if case .failed(let text) = failure.search { #expect(!text.contains("private-body")); #expect(!text.contains("talkusr.")) }
    }
    @Test func fileStoreRoundTripAndFailureUseTemporaryData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TalkPreferencesFileStore(url: root.appendingPathComponent("settings.json")), credential = credential
        let prefs = TalkMeetingPreferences(schemaVersion: 1, origin: credential.server, connectionVersion: credential.version!, rooms: ["alpha"], account: account)
        try store.save(prefs); #expect(try store.load() == prefs)
        try store.save(nil); #expect(try store.load() == nil)
        #expect(throws: (any Error).self) { try TalkPreferencesFileStore(url: root.appendingPathComponent("missing/settings.json")).save(prefs) }
    }
}
