// golos-meet/Core/Insights/OpenRouterClient.swift
import Foundation
import os

struct OpenRouterClient {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let attribution = ["HTTP-Referer": "https://golos-meet.local", "X-Title": "golos-meet"]
    static let maxAttempts = 4

    let apiKey: String
    let session: URLSession
    init(apiKey: String, session: URLSession = .shared) { self.apiKey = apiKey; self.session = session }

    /// Один не-стриминговый chat-completions. Возвращает content ассистента.
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        try await complete(model: model, messages: messages, responseFormat: responseFormat, beforeSending: {})
    }

    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?,
                              beforeSending: @escaping @Sendable () async throws -> Void) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.noAPIKey }
        let body = try buildBody(model: model, messages: messages, responseFormat: responseFormat)

        var lastError: Error = LLMError.emptyResponse
        for attempt in 1...Self.maxAttempts {
            try Task.checkCancellation()
            // Outside the retry catch: a rejected egress gate must never retry.
            try await beforeSending()
            try Task.checkCancellation()
            do {
                let content = try await send(body: body)
                return content
            } catch is CancellationError { throw CancellationError() }
            catch let LLMError.http(status, bodyText) {
                // 4xx (кроме 429) — детерминированно, не ретраим.
                if status != 429 && (400..<500).contains(status) {
                    throw LLMError.http(status: status, body: bodyText)
                }
                lastError = LLMError.http(status: status, body: bodyText)
            } catch {
                lastError = error            // transport/timeout — ретраим
            }
            if attempt < Self.maxAttempts {
                let backoff = min(30.0, pow(2.0, Double(attempt - 1))) + Double.random(in: 0...0.5)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
        throw lastError
    }

    private nonisolated func buildBody(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) throws -> Data {
        // Сборка вручную, чтобы класть только не-nil поля (как _build_payload в jurai).
        var dict: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if let rf = responseFormat {
            let data = try JSONEncoder().encode(rf)
            dict["response_format"] = try JSONSerialization.jsonObject(with: data)
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    private nonisolated func send(body: Data) async throws -> String {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 120
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in Self.attribution { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(decoding: data.prefix(500), as: UTF8.self)
            Log.llm.error("OpenRouter \(http.statusCode): \(snippet, privacy: .public)")
            throw LLMError.http(status: http.statusCode, body: snippet)
        }
        return try Self.parseContent(data)
    }

    /// Достаёт choices[0].message.content из ответа.
    static nonisolated func parseContent(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw LLMError.decode }
        guard !content.isEmpty else { throw LLMError.emptyResponse }
        return content
    }
}

extension OpenRouterClient: ChatCompleter {}
