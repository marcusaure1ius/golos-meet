import Foundation

// This executable does not link production Keychain, AppRuntime or AppPaths.
enum AppRuntime { static let isTestHost = true }
enum AppPaths { static var appSupport: URL { fatalError("No production storage in preview") } }
enum Keychain {
    enum Failure: LocalizedError { case operationFailed; var errorDescription: String? { "Synthetic storage unavailable" } }
    static func readChecked(account: String) throws -> Data? { fatalError("No Keychain in preview") }
    static func writeChecked(_ data: Data?, account: String) throws { fatalError("No Keychain in preview") }
}
@MainActor final class PreviewCredentials: TalkCredentialStoring {
    var value = TalkCredential(server: URL(string: "https://preview.example")!, token: "talkusr.synthetic-only", version: UUID())
    func load() throws -> TalkCredential? { value }
    func save(_ credential: TalkCredential?) throws { if let credential { value = credential } }
}
@MainActor final class PreviewPreferences: TalkPreferencesStoring {
    var value: TalkMeetingPreferences?
    func load() throws -> TalkMeetingPreferences? { value }
    func save(_ value: TalkMeetingPreferences?) throws { self.value = value }
}

@MainActor final class PreviewMode: TalkRecordingModeStoring {
    private var enabled = false
    func load() throws -> Bool { enabled }
    func save(_ value: Bool) throws { enabled = value }
}

@MainActor final class PreviewAutomaticMode: TalkAutomaticModeStoring {
    private var enabled = false
    func load() throws -> Bool? { enabled }
    func save(_ value: Bool) throws { enabled = value }
}
