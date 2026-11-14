import Foundation
import Testing
@testable import golos_meet

/// Instance-scoped stubs avoid sharing state with existing OpenRouter tests.
private final class TalkStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "talk.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "X-Auth-Token") ?? ""
        let status = Int(token) ?? (token == "expected-test-token" ? 200 : 401)
        let body: String
        if request.url?.path.contains("online-users") == true {
            body = "{\"onlineUsers\":[{\"uniqueId\":\"u1\",\"isAnonymous\":false,\"userInfo\":{\"key\":\"owner\"}}]}"
        } else {
            body = "{\"firstname\":\"Тест\",\"surname\":\"Пользователь\",\"domainTitle\":\"Проект\"}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct TalkAPIClientTests {
    private func client(token: String = "expected-test-token") throws -> TalkAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TalkStubProtocol.self]
        return try TalkAPIClient(server: URL(string: "https://talk.example/")!, token: token,
                                 session: URLSession(configuration: config),
                                 budget: TalkRequestBudget())
    }

    @Test func authenticatesAndDecodesProfile() async throws {
        let result = try await client().profile()
        #expect(result.firstname == "Тест")
        #expect(result.domainTitle == "Проект")
    }

    @Test(arguments: ["project123", "team_room"]) func readsOnlineParticipants(room: String) async throws {
        let result = try await client().onlineUsers(room: room)
        #expect(result.onlineUsers.first?.uniqueId == "u1")
    }

    @Test(arguments: [401, 403, 429, 500, 302])
    func mapsFailuresWithoutExposingResponseOrToken(status: Int) async throws {
        let expected: TalkAPIError = switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 429: .rateLimited
        case 302: .redirectRefused
        default: .http(status)
        }
        await #expect(throws: expected) { _ = try await client(token: String(status)).profile() }
    }

    @Test(arguments: ["http://talk.example", "https://user:pass@talk.example", "https://talk.example/a",
                      "https://talk.example?token=secret", "https://talk.example#fragment"])
    func rejectsUnsafeBaseURL(address: String) {
        #expect(throws: TalkAPIError.invalidServer) {
            try TalkAPIClient(server: URL(string: address)!, token: "test")
        }
    }

    @Test func rejectsMissingKeyAndPathInjection() async throws {
        #expect(throws: TalkAPIError.noToken) {
            try TalkAPIClient(server: URL(string: "https://talk.example")!, token: " \n")
        }
        await #expect(throws: TalkAPIError.invalidRoom) {
            _ = try await client().onlineUsers(room: "../Users/profile?token=bad")
        }
    }
}
