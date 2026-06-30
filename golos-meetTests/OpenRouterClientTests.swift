// golos-meetTests/OpenRouterClientTests.swift
import Testing
import Foundation
@testable import golos_meet

/// Мок-перехватчик: очередь ответов (status, body) + захват последнего запроса.
final class MockURLProtocol: URLProtocol {
    struct Stub { let status: Int; let body: Data }
    nonisolated(unsafe) static var stubs: [Stub] = []
    nonisolated(unsafe) static var lastRequestBody: Data?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        MockURLProtocol.lastRequest = request
        MockURLProtocol.lastRequestBody = request.httpBody
            ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
            }
        let stub = MockURLProtocol.stubs.isEmpty
            ? Stub(status: 200, body: Data())
            : MockURLProtocol.stubs.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// .serialized: тесты делят MockURLProtocol.stubs (nonisolated(unsafe) static) — параллельный прогон гонит состояние.
@Suite(.serialized) struct OpenRouterClientTests {
    private func makeClient() -> OpenRouterClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return OpenRouterClient(apiKey: "sk-or-test", session: URLSession(configuration: cfg))
    }
    private func chatBody(_ content: String) -> Data {
        Data("""
        {"choices":[{"message":{"role":"assistant","content":\(jsonString(content))}}]}
        """.utf8)
    }
    private func jsonString(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [s]), as: UTF8.self)
            .dropFirst().dropLast().description // "[\"...\"]" → "\"...\""
    }

    @Test func sendsAuthHeadersAndOpenAIBody() async throws {
        MockURLProtocol.stubs = [.init(status: 200, body: chatBody("привет"))]
        let out = try await makeClient().complete(
            model: "qwen/qwen3.6-flash",
            messages: [ChatMessage(role: "user", content: "ping")],
            responseFormat: nil)
        #expect(out == "привет")
        let req = MockURLProtocol.lastRequest!
        #expect(req.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(req.value(forHTTPHeaderField: "X-Title") == "golos-meet")
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.lastRequestBody!) as! [String: Any]
        #expect(body["model"] as? String == "qwen/qwen3.6-flash")
        #expect(body["stream"] == nil)                 // не-стриминг
        #expect(body["response_format"] == nil)        // не слать nil
        let msgs = body["messages"] as! [[String: Any]]
        #expect(msgs.first?["content"] as? String == "ping")
    }

    @Test func retriesOn5xxThenSucceeds() async throws {
        MockURLProtocol.stubs = [
            .init(status: 503, body: Data("upstream".utf8)),
            .init(status: 200, body: chatBody("ок")),
        ]
        let out = try await makeClient().complete(
            model: "m", messages: [ChatMessage(role: "user", content: "x")], responseFormat: nil)
        #expect(out == "ок")
        #expect(MockURLProtocol.stubs.isEmpty)         // обе попытки израсходованы
    }

    @Test func failsFastOn4xx() async throws {
        MockURLProtocol.stubs = [.init(status: 401, body: Data("bad key".utf8))]
        await #expect(throws: LLMError.self) {
            _ = try await makeClient().complete(
                model: "m", messages: [ChatMessage(role: "user", content: "x")], responseFormat: nil)
        }
        #expect(MockURLProtocol.stubs.isEmpty)         // ровно одна попытка (без ретрая)
    }
}
