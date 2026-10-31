import Foundation

nonisolated enum TalkRoomConfigurationError: Error { case invalidIdentity, invalidRooms }

/// Explicit user identity, never inferred from profile names or conference uniqueId.
/// The caller must obtain and confirm userKey through the documented user list.
nonisolated struct TalkRoomConfiguration: Equatable, Sendable {
    let credential: TalkCredential
    let rooms: [String]
    let userKey: String
    init(credential: TalkCredential, rooms inputs: [String], userKey: String) throws {
        let origin = try TalkAPIClient.normalizedServer(credential.server)
        _ = try TalkAPIClient(server: origin, token: credential.token)
        guard !userKey.isEmpty, userKey == userKey.trimmingCharacters(in: .whitespacesAndNewlines),
              !userKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TalkRoomConfigurationError.invalidIdentity
        }
        let rooms = try Set(inputs.map { try Self.room($0, origin: origin) }).sorted()
        guard !rooms.isEmpty, rooms.count <= 10 else { throw TalkRoomConfigurationError.invalidRooms }
        self.credential = TalkCredential(server: origin, token: credential.token)
        self.rooms = rooms
        self.userKey = userKey
    }

    private static func room(_ input: String, origin: URL) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var room = value
        if value.contains("://") {
            guard var parts = URLComponents(string: value), parts.query == nil, parts.fragment == nil,
                  parts.percentEncodedPath == parts.path else { throw TalkAPIError.invalidRoom }
            let path = parts.path
            parts.path = ""
            guard let server = parts.url, try TalkAPIClient.normalizedServer(server) == origin,
                  path.hasPrefix("/") else { throw TalkAPIError.invalidRoom }
            room = String(path.dropFirst())
            if room.hasSuffix("/") { room.removeLast() }
        }
        guard !room.isEmpty, room.utf8.count <= 128, room.unicodeScalars.allSatisfy({
            (97...122).contains($0.value) || (48...57).contains($0.value)
        }) else { throw TalkAPIError.invalidRoom }
        return room
    }
}
