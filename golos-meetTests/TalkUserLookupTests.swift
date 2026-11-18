import Foundation
import Testing
@testable import golos_meet

private final class UserLookupProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lookup.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let query = components.queryItems ?? []
        let email = query.first?.value
        let valid = request.url!.absoluteString.contains("%2B") && request.url!.absoluteString.contains("%26") && request.url?.path == "/api/Users" && request.httpMethod == "GET" && query.count == 1
            && query.first?.name == "email" && email == "me+tag&part@example.ru" && request.url?.fragment == nil
        let mode = request.value(forHTTPHeaderField: "X-Auth-Token")
        let status = valid ? (mode == "denied" ? 403 : 200) : 400
        let body = mode == "invalid" ? #"{"users":[{"key":""}]}"# : mode == "denied" ? "private-body" : #"{"users":[{"key":"owner","login":"me","firstname":"Тест","surname":"Пользователь","email":"me+tag&part@example.ru"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Suite struct TalkUserLookupTests {
    private func client(_ token: String = "synthetic") throws -> TalkAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserLookupProtocol.self]
        return try TalkAPIClient(server: URL(string: "https://lookup.example")!, token: token,
                                 session: URLSession(configuration: configuration), budget: TalkRequestBudget())
    }
    @Test func emailFilterIsEncodedAsOneQueryParameterAndDecodesIdentity() async throws {
        let result = try await client().users(email: " me+tag&part@example.ru ")
        #expect(result.first?.key == "owner"); #expect(result.first?.login == "me")
        #expect(result.first?.name == "Тест Пользователь")
    }
    @Test func malformedIdentityAndHTTPBodyStaySafe() async throws {
        await #expect(throws: TalkAPIError.invalidResponse) { _ = try await client("invalid").users(email: "me+tag&part@example.ru") }
        await #expect(throws: TalkAPIError.forbidden) { _ = try await client("denied").users(email: "me+tag&part@example.ru") }
    }
    @Test(arguments: ["", "invalid", "a@@example.ru", "a@", "a@.ru", "a@host.", "a b@example.ru", "a\rb@example.ru"])
    func invalidEmailIsRejectedBeforeTransport(email: String) async throws {
        await #expect(throws: TalkAPIError.invalidEmail) { _ = try await client().users(email: email) }
    }
}
