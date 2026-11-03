import Foundation
import Testing
@testable import golos_meet

@MainActor private final class AutoMode: TalkAutomaticModeStoring {
    var value: Bool?
    var fail = false
    func load() throws -> Bool? { if fail { throw URLError(.cannotOpenFile) }; return value }
    func save(_ enabled: Bool) throws { if fail { throw URLError(.cannotWriteToFile) }; value = enabled }
}
@MainActor private final class AutoCredentials: TalkCredentialStoring {
    var value: TalkCredential? = .init(server: URL(string: "https://mode.example")!, token: "talkusr.synthetic", version: UUID())
    func load() throws -> TalkCredential? { value }
    func save(_ value: TalkCredential?) throws { self.value = value }
}
@MainActor private final class AutoPreferences: TalkPreferencesStoring {
    var value: TalkMeetingPreferences?
    func load() throws -> TalkMeetingPreferences? { value }
    func save(_ value: TalkMeetingPreferences?) throws { self.value = value }
}
@MainActor private struct AutoOldMode: TalkRecordingModeStoring {
    func load() throws -> Bool { true }
    func save(_ value: Bool) throws { Issue.record("New diagnostic mode must not modify legacy recording preferences") }
}

@MainActor @Suite struct TalkAutomaticModeTests {
    private let account = TalkUserAccount(key: "owner", login: nil, firstname: nil, surname: nil, email: "owner@example.ru")

    @Test func automaticModeNeedsIdentityButNotRoomsAndNeverFallsBackToRecording() throws {
        let mode = AutoMode(), credentials = AutoCredentials(), preferences = AutoPreferences()
        let credential = credentials.value!
        preferences.value = .init(schemaVersion: 1, origin: credential.server, connectionVersion: credential.version!, rooms: [], account: account)
        mode.value = true
        #expect(TalkRuntimeSettings.load(mode: AutoOldMode(), credentials: credentials, preferences: preferences, automaticMode: mode)
                == .automatic(try .init(credential: credential, userKey: "owner"), enabled: true))
        credentials.value = .init(server: credential.server, token: "talkusr.rotated", version: UUID())
        #expect(TalkRuntimeSettings.load(mode: AutoOldMode(), credentials: credentials, preferences: preferences, automaticMode: mode) == .automatic(nil, enabled: true))
        credentials.value = nil
        #expect(TalkRuntimeSettings.load(mode: AutoOldMode(), credentials: credentials, preferences: preferences, automaticMode: mode) == .automatic(nil, enabled: true))
        mode.value = false
        #expect(TalkRuntimeSettings.load(mode: AutoOldMode(), credentials: credentials, preferences: preferences, automaticMode: mode) == .automatic(nil, enabled: false))
        mode.fail = true
        #expect(TalkRuntimeSettings.load(mode: AutoOldMode(), credentials: credentials, preferences: preferences, automaticMode: mode) == .unavailable)
    }

    @Test func explicitSwitchChecksBindingDoesNotCommitRoomDraftOrChangeLegacyMode() throws {
        let mode = AutoMode(), credentials = AutoCredentials(), preferences = AutoPreferences()
        let model = TalkMeetingSettingsModel(preferences: preferences, credentials: credentials, mode: AutoOldMode(), automaticMode: mode)
        model.bind(credentials.value!)
        #expect(!model.setAutomaticDetectionEnabled(true))
        let credential = credentials.value!
        preferences.value = .init(schemaVersion: 1, origin: credential.server, connectionVersion: credential.version!, rooms: [], account: account)
        model.bind(credential); model.rooms = [.init(input: "unsaved_room")]
        #expect(model.setAutomaticDetectionEnabled(true))
        #expect(model.automaticDetectionEnabled && model.automaticDetectionSelected)
        #expect(mode.value == true && preferences.value?.rooms.isEmpty == true)
        credentials.value = .init(server: credential.server, token: "talkusr.new", version: UUID())
        #expect(!model.setAutomaticDetectionEnabled(true))
        #expect(model.setAutomaticDetectionEnabled(false)) // Turning off remains possible after key loss.
        #expect(mode.value == false && model.automaticDetectionSelected)
        mode.fail = true
        #expect(!model.setAutomaticDetectionEnabled(false))
        #expect(model.automaticModeError != nil)
    }

    @Test func fileModeDistinguishesMissingDisabledAndCorrupt() throws {
        let root = AppRuntime.testStorage.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TalkAutomaticModeFileStore(url: root.appendingPathComponent("mode.json"))
        #expect(try store.load() == nil)
        try store.save(false); #expect(try store.load() == false)
        try store.save(true); #expect(try store.load() == true)
        try Data("broken".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
    }
}
