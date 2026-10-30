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

    struct User: Decodable, Sendable {
        let uniqueId: String
        let isAnonymous: Bool
        let anonymousId: String?
    }
}

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

    init(server: URL, token: String, session: URLSession? = nil) throws {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw TalkAPIError.invalidServer }
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TalkAPIError.noToken
        }
        components.path = ""
        guard let base = components.url else { throw TalkAPIError.invalidServer }
        self.server = base
        self.token = key
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
        return try await get(path: "api/Rooms/\(room)/online-users")
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        var request = URLRequest(url: server.appendingPathComponent(path))
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
        case 429: throw TalkAPIError.rateLimited
        default: throw TalkAPIError.http(http.statusCode)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw TalkAPIError.invalidResponse
        }
        return value
    }
}
