import Foundation
import Combine

/// Stored as one Keychain item, so a key can never be silently reused for a new host.
nonisolated struct TalkCredential: Codable, Equatable, Sendable {
    let server: URL
    let token: String
    let version: UUID?
    init(server: URL, token: String, version: UUID? = nil) {
        self.server = server; self.token = token; self.version = version
    }
}

@MainActor
protocol TalkCredentialStoring {
    func load() throws -> TalkCredential?
    func save(_ credential: TalkCredential?) throws
}

@MainActor
struct TalkKeychainStore: TalkCredentialStoring {
    // Separate from the earlier unbound key account; never migrate an unknown host.
    private let account = "kontur-talk-connection-v1"

    func load() throws -> TalkCredential? {
        guard let data = try Keychain.readChecked(account: account) else { return nil }
        guard let credential = try? JSONDecoder().decode(TalkCredential.self, from: data) else {
            throw Keychain.Failure.operationFailed
        }
        return credential
    }

    func save(_ credential: TalkCredential?) throws {
        try Keychain.writeChecked(try credential.map { try JSONEncoder().encode($0) }, account: account)
    }
}

@MainActor
final class TalkConnectionModel: ObservableObject {
    enum Diagnostic: Equatable {
        case unchecked, checking, connected, failed(String)

        var text: String {
            switch self {
            case .unchecked: "Подключение ещё не проверено."
            case .checking: "Проверяем доступ к профилю…"
            case .connected: "PAT принят. Доступ к профилю подтверждён."
            case .failed(let message): message
            }
        }
    }

    @Published var serverAddress = "https://alfabank.ktalk.ru" { didSet { if oldValue != serverAddress { invalidate() } } }
    // Always blank on opening: the saved secret is never populated back into the UI.
    @Published var newToken = "" { didSet { if oldValue != newToken { invalidate() } } }
    @Published private(set) var hasSavedCredential = false
    @Published private(set) var diagnostic: Diagnostic = .unchecked
    @Published private(set) var storageMessage: String?

    let meetingSettings: TalkMeetingSettingsModel

    private let store: any TalkCredentialStoring
    private let checkProfile: @Sendable (TalkCredential) async throws -> Void
    private var revision = 0

    init(store: (any TalkCredentialStoring)? = nil,
         preferences: (any TalkPreferencesStoring)? = nil,
         lookup: TalkMeetingSettingsModel.Lookup? = nil,
         checkProfile: @escaping @Sendable (TalkCredential) async throws -> Void = { credential in
             _ = try await TalkAPIClient(server: credential.server, token: credential.token).profile()
         }) {
        let store = store ?? TalkKeychainStore()
        self.store = store
        self.meetingSettings = TalkMeetingSettingsModel(preferences: preferences ?? TalkPreferencesFileStore(), lookup: lookup)
        self.checkProfile = checkProfile
        do {
            if let credential = try store.load() {
                serverAddress = credential.server.absoluteString
                hasSavedCredential = true
                meetingSettings.bind(credential)
            }
        } catch { storageMessage = Keychain.Failure.operationFailed.localizedDescription }
    }

    private func invalidate() {
        revision += 1
        diagnostic = .unchecked
        storageMessage = nil
        meetingSettings.unbind()
    }

    private func candidate() throws -> TalkCredential {
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address) else { throw TalkAPIError.invalidServer }
        let saved = try store.load()
        let typed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate even before matching the saved origin (canonical trailing slash).
        let normalized = try TalkAPIClient(server: url, token: "validation-only").server
        let token: String
        if !typed.isEmpty { token = typed }
        else if let saved, saved.server == normalized { token = saved.token }
        else { throw TalkAPIError.noToken }
        guard token.hasPrefix("talkusr.") else { throw TalkAPIError.noToken }
        _ = try TalkAPIClient(server: normalized, token: token)
        return TalkCredential(server: normalized, token: token)
    }

    @discardableResult
    func save() -> Bool {
        do {
            let candidate = try candidate()
            let old = try store.load()
            let unchanged = old?.server == candidate.server && old?.token == candidate.token
            let credential = TalkCredential(server: candidate.server, token: candidate.token,
                                            version: unchanged ? (old?.version ?? UUID()) : UUID())
            try store.save(credential)
            serverAddress = credential.server.absoluteString
            newToken = ""
            hasSavedCredential = true
            meetingSettings.bind(credential)
            storageMessage = "PAT сохранён в Keychain для этого адреса."
            return true
        } catch {
            diagnostic = .failed(Self.safeMessage(error))
            return false
        }
    }

    func delete() {
        invalidate()
        do {
            try store.save(nil)
            newToken = ""
            hasSavedCredential = false
            meetingSettings.removePreferences()
            storageMessage = "Сохранённый PAT удалён с этого Mac."
        } catch { diagnostic = .failed(Self.safeMessage(error)) }
    }

    /// Only a deliberate user action calls this method. It does not enable recording.
    func verify() async {
        guard diagnostic != .checking else { return }
        let credential: TalkCredential
        do { credential = try candidate() }
        catch { diagnostic = .failed(Self.safeMessage(error)); return }
        let requestRevision = revision
        diagnostic = .checking
        do {
            try await checkProfile(credential)
            guard requestRevision == revision, !Task.isCancelled else { return }
            diagnostic = .connected
        } catch {
            guard requestRevision == revision, !Task.isCancelled else { return }
            diagnostic = .failed(Self.safeMessage(error))
        }
    }

    static func safeMessage(_ error: Error) -> String {
        if let error = error as? TalkAPIError { return error.localizedDescription }
        if error is Keychain.Failure { return Keychain.Failure.operationFailed.localizedDescription }
        // Do not display arbitrary server/transport error descriptions or response bodies.
        return "API Толка недоступен. Проверьте сеть и адрес пространства, затем повторите проверку."
    }
}
