import Foundation

nonisolated enum TalkAPIError: LocalizedError, Equatable {
    case invalidServer
    case noToken
    case unauthorized
    case forbidden
    case rateLimited
    case http(Int)
    case invalidResponse
    case redirectRefused
    case invalidRoom
    case invalidEmail

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Укажите HTTPS-адрес пространства Толка без пути и параметров."
        case .noToken: return "Добавьте отдельный API-ключ Толка. Ключ OpenRouter для этого не подходит."
        case .unauthorized: return "Толк не принял ключ: он неверен, отозван или истёк."
        case .forbidden: return "Ключу не хватает прав на этот метод Толка."
        case .rateLimited: return "Достигнут лимит API Толка. Повторите запрос позже."
        case .http(let status): return "Толк вернул ошибку HTTP \(status)."
        case .invalidResponse: return "Не удалось прочитать ответ API Толка."
        case .redirectRefused: return "Адрес Толка перенаправляет запрос. Проверьте адрес пространства."
        case .invalidEmail: return "Укажите рабочую почту целиком, например name@example.ru."
        case .invalidRoom: return "Некорректный идентификатор комнаты Толка."
        }
    }
}

nonisolated struct TalkProfile: Decodable, Equatable, Sendable {
    let firstname: String?
    let surname: String?
    let domainTitle: String?
}

nonisolated struct TalkOnlineUsers: Decodable, Sendable {
    let onlineUsers: [User]

    func validate() throws {
        // An unidentified registered participant could be our target. Do not
        // turn malformed identity data into confirmed absence.
        guard onlineUsers.allSatisfy({ user in
            !user.uniqueId.isEmpty && (user.isAnonymous || user.userInfo.map {
                !$0.key.isEmpty && $0.key == $0.key.trimmingCharacters(in: .whitespacesAndNewlines)
                    && !$0.key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            } == true)
        }) else { throw TalkAPIError.invalidResponse }
    }

    struct User: Decodable, Sendable {
        let uniqueId: String
        let isAnonymous: Bool
        let anonymousId: String?
        let userInfo: Identity?
        struct Identity: Decodable, Sendable { let key: String }
    }
}

nonisolated struct TalkUserAccount: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let login: String?
    let firstname: String?
    let surname: String?
    let email: String?
    var id: String { key }
    var name: String { [firstname, surname].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
}

nonisolated struct TalkUserSearch: Decodable, Sendable { let users: [TalkUserAccount] }

/// Never forward a credential across an HTTP redirect, even to another HTTPS
/// host. Error response bodies are not logged: they can contain private data.
private final class TalkRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated struct TalkAPIClient: Sendable {
    let server: URL
    private let token: String
    private let session: URLSession
    private let budget: TalkRequestBudget

    static func normalizedServer(_ server: URL) throws -> URL {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw TalkAPIError.invalidServer }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        components.path = ""
        guard let base = components.url else { throw TalkAPIError.invalidServer }
        return base
    }

    init(server: URL, token: String, session: URLSession? = nil,
         budget: TalkRequestBudget = .shared) throws {
        let base = try Self.normalizedServer(server)
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TalkAPIError.noToken
        }
        self.server = base
        self.token = key
        self.budget = budget
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    func profile() async throws -> TalkProfile {
        try await get(path: "api/Users/profile")
    }

    func onlineUsers(room: String) async throws -> TalkOnlineUsers {
        guard !room.isEmpty, room.unicodeScalars.allSatisfy({
            (97...122).contains($0.value) || (48...57).contains($0.value)
        }) else { throw TalkAPIError.invalidRoom }
        let result: TalkOnlineUsers = try await get(path: "api/Rooms/\(room)/online-users")
        try result.validate()
        return result
    }

    static func validatedEmail(_ value: String) throws -> String {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.utf8.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !email.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw TalkAPIError.invalidEmail
        }
        return email
    }

    func users(email: String) async throws -> [TalkUserAccount] {
        let email = try Self.validatedEmail(email)
        let result: TalkUserSearch = try await get(path: "api/Users", query: [URLQueryItem(name: "email", value: email)])
        guard result.users.count <= 1000,
              Set(result.users.map(\.key)).count == result.users.count,
              result.users.allSatisfy({ !$0.key.isEmpty && $0.key == $0.key.trimmingCharacters(in: .whitespacesAndNewlines)
                  && !$0.key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw TalkAPIError.invalidResponse }
        return result.users
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem] = []) async throws -> T {
        try await budget.acquire(origin: server)
        try Task.checkCancellation()
        var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            // Preserve plus-addressed email through form-style query decoders.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw TalkAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: TalkRedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw TalkAPIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 300..<400: throw TalkAPIError.redirectRefused
        case 401: throw TalkAPIError.unauthorized
        case 403: throw TalkAPIError.forbidden
        case 429:
            await budget.rateLimited(origin: server, retryAfter: Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
            throw TalkAPIError.rateLimited
        default: throw TalkAPIError.http(http.statusCode)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw TalkAPIError.invalidResponse
        }
        return value
    }

    private static func retryDelay(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
