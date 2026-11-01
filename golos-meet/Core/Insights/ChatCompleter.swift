import Foundation

struct ChatMessage: Codable, Equatable {
    let role: String      // "system" | "user" | "assistant"
    let content: String
}

/// Минимальное представление произвольного JSON — для json_schema в response_format.
enum JSONValue: Encodable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .null:          try c.encodeNil()
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

struct ResponseFormat: Encodable, Equatable {
    let type: String           // "json_schema"
    let name: String
    let schema: JSONValue

    static func == (l: ResponseFormat, r: ResponseFormat) -> Bool { l.type == r.type && l.name == r.name }

    enum CodingKeys: String, CodingKey { case type, json_schema }
    enum SchemaKeys: String, CodingKey { case name, schema }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        var s = c.nestedContainer(keyedBy: SchemaKeys.self, forKey: .json_schema)
        try s.encode(name, forKey: .name)
        try s.encode(schema, forKey: .schema)
    }

    static func jsonSchema(name: String, schema: JSONValue) -> ResponseFormat {
        ResponseFormat(type: "json_schema", name: name, schema: schema)
    }
}

enum LLMError: Error, Equatable {
    case noAPIKey
    case http(status: Int, body: String)
    case decode
    case emptyResponse
}

/// Абстракция над транспортом — для тестируемости генератора.
protocol ChatCompleter {
    // nonisolated: совпадает с OpenRouterClient.complete (nonisolated).
    // Необходимо при SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, иначе
    // OpenRouterClient не удовлетворяет требованию (@MainActor vs nonisolated).
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String
    /// Retrying transports must run this gate before EVERY outbound attempt.
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?,
                              beforeSending: @escaping @Sendable () async throws -> Void) async throws -> String
}

extension ChatCompleter {
    /// Single-attempt adapters can use the default. Retrying adapters override it.
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?,
                              beforeSending: @escaping @Sendable () async throws -> Void) async throws -> String {
        try Task.checkCancellation()
        try await beforeSending()
        try Task.checkCancellation()
        return try await complete(model: model, messages: messages, responseFormat: responseFormat)
    }
}
