import Foundation
import Combine

nonisolated struct TalkMeetingPreferences: Codable, Equatable {
    let schemaVersion: Int
    let origin: URL
    let connectionVersion: UUID
    let rooms: [String]
    let account: TalkUserAccount?
}

@MainActor protocol TalkPreferencesStoring {
    func load() throws -> TalkMeetingPreferences?
    func save(_ value: TalkMeetingPreferences?) throws
}

@MainActor struct TalkPreferencesFileStore: TalkPreferencesStoring {
    let url: URL
    init(url: URL? = nil) { self.url = url ?? AppPaths.appSupport.appendingPathComponent("talk-meeting-settings.json") }
    func load() throws -> TalkMeetingPreferences? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TalkMeetingPreferences.self, from: Data(contentsOf: url))
    }
    func save(_ value: TalkMeetingPreferences?) throws {
        if let value {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

@MainActor final class TalkMeetingSettingsModel: ObservableObject {
    typealias Lookup = @Sendable (TalkCredential, String) async throws -> [TalkUserAccount]
    enum SearchState: Equatable { case idle, loading, results([TalkUserAccount]), failed(String) }
    struct Room: Identifiable { let id = UUID(); var input: String }
    @Published var rooms: [Room] = [] { didSet { message = nil } }
    @Published var email = "" { didSet { cancelSearch() } }
    @Published private(set) var search: SearchState = .idle
    @Published private(set) var confirmed: TalkUserAccount?
    @Published private(set) var isBound = false
    @Published private(set) var apiEnabled = false
    @Published private(set) var modeError: String?
    @Published private(set) var message: String?
    private let mode: any TalkRecordingModeStoring
    private let store: any TalkPreferencesStoring
    private let lookup: Lookup
    private var credential: TalkCredential?
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?
    private var modeListener: UUID?

    init(preferences: any TalkPreferencesStoring, mode: (any TalkRecordingModeStoring)? = nil, lookup: Lookup? = nil) {
        store = preferences
        self.mode = mode ?? TalkRecordingModeFileStore()
        do { apiEnabled = try self.mode.load() }
        catch { modeError = "Не удалось прочитать режим автозаписи. Выберите и сохраните режим заново." }
        let testHost = AppRuntime.isTestHost
        self.lookup = lookup ?? { credential, email in
            guard !testHost else { throw TalkAPIError.invalidResponse }
            return try await TalkAPIClient(server: credential.server, token: credential.token).users(email: email)
        }
        modeListener = TalkSettingsChanges.observe { [weak self] in
            guard let self else { return }
            do { self.apiEnabled = try self.mode.load(); self.modeError = nil }
            catch { self.modeError = "Не удалось прочитать режим автозаписи. Сохраните выбор заново." }
        }
    }
    deinit {
        task?.cancel()
        let listener = modeListener
        Task { @MainActor in if let listener { TalkSettingsChanges.remove(listener) } }
    }

    func unbind() {
        cancelSearch(); email = ""; credential = nil; isBound = false
        confirmed = nil; rooms = []; message = nil
    }
    func bind(_ credential: TalkCredential) {
        unbind()
        guard credential.version != nil else {
            message = "Сохраните PAT ещё раз, затем подтвердите аккаунт."; return
        }
        self.credential = credential; isBound = true
        do {
            if let value = try store.load(), value.schemaVersion == 1,
               value.origin == credential.server, value.connectionVersion == credential.version {
                // Revalidate persisted data; never trust an edited file as runtime configuration.
                for room in value.rooms { _ = try normalized(room) }
                guard value.rooms.count <= 10 else { throw TalkRoomConfigurationError.invalidRooms }
                rooms = Array(Set(value.rooms)).sorted().map { Room(input: $0) }
                if let account = value.account {
                    _ = try TalkRoomConfiguration(credential: credential, rooms: ["validation"], userKey: account.key)
                    confirmed = account
                }
            }
        } catch { message = "Не удалось прочитать настройки комнат. Проверьте и сохраните их заново." }
    }
    func removePreferences() {
        unbind()
        do { try store.save(nil) }
        catch { message = "PAT удалён, но файл настроек удалить не удалось. Прежнее подтверждение больше не действует." }
    }
    func normalized(_ input: String) throws -> String {
        guard let credential else { throw TalkAPIError.noToken }
        return try TalkRoomConfiguration(credential: credential, rooms: [input], userKey: "validation").rooms[0]
    }
    func roomError(_ input: String) -> String? {
        do { _ = try normalized(input); return nil }
        catch { return "Нужен ID из строчных латинских букв и цифр или ссылка этого пространства без параметров." }
    }
    func addRoom() { rooms.append(Room(input: "")) }
    func removeRoom(_ id: UUID) { rooms.removeAll { $0.id == id } }

    @discardableResult func saveRooms() -> Bool {
        do {
            let normalized = try Set(rooms.map { try self.normalized($0.input) }).sorted()
            guard normalized.count <= 10 else { throw TalkRoomConfigurationError.invalidRooms }
            try persist(rooms: normalized, account: confirmed)
            rooms = normalized.map { Room(input: $0) }
            message = normalized.isEmpty ? "Список комнат очищен." : "Комнаты сохранены."
            return true
        } catch {
            message = "Комнаты не сохранены. Исправьте адреса; допустимо до 10 разных комнат. При повторной ошибке проверьте доступ к файлу настроек."
            return false
        }
    }
    func cancelSearch() {
        revision &+= 1; task?.cancel(); task = nil; search = .idle
    }
    func findAccount() {
        cancelSearch()
        guard let credential else { search = .failed("Сначала сохраните PAT для этого пространства."); return }
        let query: String
        do { query = try TalkAPIClient.validatedEmail(email) }
        catch { search = .failed(TalkAPIError.invalidEmail.localizedDescription); return }
        let current = revision, lookup = lookup
        search = .loading
        task = Task { [weak self] in
            do {
                let users = try await lookup(credential, query)
                guard !Task.isCancelled, self?.revision == current else { return }
                self?.search = .results(users)
            } catch {
                guard !Task.isCancelled, self?.revision == current else { return }
                self?.search = .failed(TalkConnectionModel.safeMessage(error))
            }
            self?.task = nil
        }
    }
    @discardableResult func confirm(_ account: TalkUserAccount) -> Bool {
        guard case .results(let users) = search, users.contains(account), let credential else { return false }
        do {
            _ = try TalkRoomConfiguration(credential: credential, rooms: ["validation"], userKey: account.key)
            // Identity confirmation must not silently commit unsaved room edits.
            let old = try store.load()
            let boundRooms = old?.origin == credential.server && old?.connectionVersion == credential.version ? old!.rooms : []
            try persist(rooms: boundRooms, account: account)
            confirmed = account; cancelSearch(); message = "Аккаунт подтверждён."
            return true
        } catch { message = "Не удалось сохранить подтверждение. Повторите попытку."; return false }
    }
    @discardableResult func setAPIEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                guard let credential, let value = try store.load(), value.origin == credential.server,
                      value.connectionVersion == credential.version, let account = value.account else { throw TalkAPIError.noToken }
                _ = try TalkRoomConfiguration(credential: credential, rooms: value.rooms, userKey: account.key)
            }
            try mode.save(enabled)
            apiEnabled = enabled
            modeError = nil
            message = enabled ? "API-автозапись включена для сохранённых комнат и аккаунта." : "API-режим выключен. Автозапись использует эвристику аудио и окон."
            TalkSettingsChanges.post()
            return true
        } catch {
            if error is TalkAPIError || error is TalkRoomConfigurationError {
                message = "Сначала сохраните комнаты и подтвердите аккаунт для этого PAT."
            } else { modeError = "Не удалось сохранить режим автозаписи. Повторите попытку." }
            return false
        }
    }

    private func persist(rooms: [String], account: TalkUserAccount?) throws {
        guard let credential, let version = credential.version else { throw TalkAPIError.noToken }
        if !rooms.isEmpty { _ = try TalkRoomConfiguration(credential: credential, rooms: rooms, userKey: account?.key ?? "validation") }
        try store.save(TalkMeetingPreferences(schemaVersion: 1, origin: credential.server,
                                             connectionVersion: version, rooms: rooms, account: account))
        TalkSettingsChanges.post()
    }
}
