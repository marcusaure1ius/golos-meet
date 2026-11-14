import Foundation

/// Synchronous MainActor delivery: invalidate old API generations during save,
/// before any queued network completion can trigger recording with old settings.
@MainActor enum TalkSettingsChanges {
    private static var listeners: [UUID: @MainActor () -> Void] = [:]
    static func observe(_ listener: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); listeners[id] = listener; return id
    }
    static func remove(_ id: UUID) { listeners[id] = nil }
    static func post() { Array(listeners.values).forEach { $0() } }
}

@MainActor protocol TalkRecordingModeStoring {
    func load() throws -> Bool
    func save(_ enabled: Bool) throws
}

/// Independent from the credential/identity binding. Losing a key must never
/// silently switch an explicitly enabled API mode to window/microphone heuristics.
@MainActor struct TalkRecordingModeFileStore: TalkRecordingModeStoring {
    let url: URL
    init(url: URL? = nil) { self.url = url ?? AppPaths.appSupport.appendingPathComponent("talk-api-mode.json") }
    func load() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: url))
    }
    func save(_ enabled: Bool) throws { try JSONEncoder().encode(enabled).write(to: url, options: .atomic) }
}

nonisolated enum TalkRuntimeSelection: Equatable {
    case legacy
    case api(TalkRoomConfiguration?)
    case automatic(TalkAutomaticConfiguration?, enabled: Bool)
    case unavailable
}

@MainActor enum TalkRuntimeSettings {
    static func load(mode: any TalkRecordingModeStoring, credentials: any TalkCredentialStoring,
                     preferences: any TalkPreferencesStoring,
                     automaticMode: (any TalkAutomaticModeStoring)? = nil) -> TalkRuntimeSelection {
        do {
            if let enabled = try automaticMode?.load() {
                guard enabled else { return .automatic(nil, enabled: false) }
                guard let credential = try credentials.load(), let version = credential.version,
                      let value = try preferences.load(), value.schemaVersion == 1,
                      value.origin == credential.server, value.connectionVersion == version,
                      let account = value.account else { return .automatic(nil, enabled: true) }
                return .automatic(try TalkAutomaticConfiguration(credential: credential, userKey: account.key), enabled: true)
            }
            guard try mode.load() else { return .legacy }
            guard let credential = try credentials.load(), let version = credential.version,
                  let value = try preferences.load(), value.schemaVersion == 1,
                  value.origin == credential.server, value.connectionVersion == version,
                  let account = value.account, !value.rooms.isEmpty else { return .api(nil) }
            return .api(try TalkRoomConfiguration(credential: credential, rooms: value.rooms, userKey: account.key))
        } catch { return .unavailable }
    }

    static func production() -> TalkRuntimeSelection {
        // Must precede even constructing default stores/paths.
        guard !AppRuntime.isTestHost else { return .unavailable }
        return load(mode: TalkRecordingModeFileStore(), credentials: TalkKeychainStore(), preferences: TalkPreferencesFileStore(),
                    automaticMode: TalkAutomaticModeFileStore())
    }
}

extension TalkRoomPresence {
    var statusText: String {
        switch self {
        case .present: "API Толка: участие подтверждено"
        case .absent: "API Толка: встречи нет"
        case .unknown(let reason):
            switch reason {
            case .checking: "API Толка: ожидаем свежий ответ…"
            case .paused: "API Толка: пауза на время сна"
            case .stopped: "API Толка: наблюдение остановлено"
            case .stale: "API Толка: ответ устарел, участие неизвестно"
            case .unauthorized: "API Толка: ключ не принят, участие неизвестно"
            case .forbidden: "API Толка: нет доступа, участие неизвестно"
            case .rateLimited: "API Толка: лимит запросов, участие неизвестно"
            case .invalidResponse: "API Толка: некорректный ответ, участие неизвестно"
            case .unavailable: "API Толка: сеть недоступна, участие неизвестно"
            }
        }
    }
}
