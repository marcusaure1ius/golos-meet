import Foundation

@MainActor protocol TalkAutomaticModeStoring {
    /// nil preserves old installations; false explicitly selects disabled,
    /// read-only discovery and must never fall back to legacy recording.
    func load() throws -> Bool?
    func save(_ enabled: Bool) throws
}

@MainActor struct TalkAutomaticModeFileStore: TalkAutomaticModeStoring {
    let url: URL
    init(url: URL? = nil) { self.url = url ?? AppPaths.appSupport.appendingPathComponent("talk-automatic-discovery.json") }
    func load() throws -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: url))
    }
    func save(_ enabled: Bool) throws { try JSONEncoder().encode(enabled).write(to: url, options: .atomic) }
}
