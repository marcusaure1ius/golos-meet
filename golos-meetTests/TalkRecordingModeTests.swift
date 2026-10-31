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
    func load() throws -> TalkCredential? { loads += 1; return credential }
    func save(_ value: TalkCredential?) throws { credential = value }
}
@MainActor private final class RuntimePreferences: TalkPreferencesStoring {
    var value: TalkMeetingPreferences?
    func load() throws -> TalkMeetingPreferences? { value }
    func save(_ value: TalkMeetingPreferences?) throws { self.value = value }
}
@Suite @MainActor struct TalkRecordingModeTests {
    private var credential: TalkCredential { .init(server: URL(string: "https://mode.example")!, token: "talkusr.synthetic", version: UUID()) }
    @Test func enablingRequiresSavedBindingAndDoesNotCommitDrafts() {
        let mode = RuntimeMode(), preferences = RuntimePreferences()
        let model = TalkMeetingSettingsModel(preferences: preferences, mode: mode)
        #expect(!model.setAPIEnabled(true)); #expect(!mode.enabled)
        let credential = credential
        model.bind(credential); model.rooms = [.init(input: "alpha")]
        #expect(!model.setAPIEnabled(true))
        let account = TalkUserAccount(key: "owner", login: nil, firstname: nil, surname: nil, email: "test@example.ru")
        preferences.value = .init(schemaVersion: 1, origin: credential.server, connectionVersion: credential.version!, rooms: ["saved"], account: account)
        #expect(model.setAPIEnabled(true)); #expect(mode.enabled)
        #expect(preferences.value?.rooms == ["saved"])
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
        let model = TalkMeetingSettingsModel(preferences: RuntimePreferences(), mode: mode)
        mode.fail = true
        #expect(!model.setAPIEnabled(false))
        #expect(model.apiEnabled && mode.enabled)
        #expect(model.modeError != nil)
    }
    @Test func modeChangeRefreshesOtherOpenSettingsWithoutLosingRoomDrafts() {
        let mode = RuntimeMode(); mode.enabled = true
        let preferences = RuntimePreferences()
        let first = TalkMeetingSettingsModel(preferences: preferences, mode: mode)
        let second = TalkMeetingSettingsModel(preferences: preferences, mode: mode)
        second.bind(credential); second.rooms = [.init(input: "unsaved")]
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
        let model = TalkMeetingSettingsModel(preferences: RuntimePreferences(), mode: file)
        #expect(model.setAPIEnabled(false)); #expect(delivered); #expect(try !file.load())
        try Data("corrupt".utf8).write(to: file.url)
        #expect(throws: (any Error).self) { try file.load() }
    }
}
