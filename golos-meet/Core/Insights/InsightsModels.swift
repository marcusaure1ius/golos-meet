import Foundation

/// Один пункт действий из встречи.
struct ActionPoint: Equatable, Identifiable {
    let id: UUID                 // генерится в Swift при разборе ответа LLM; для SwiftUI
    let text: String
    var owner: String? = nil     // ответственный, если выделен (nil — норма)
    var done: Bool = false        // отмечен как выполненный в UI
}

// MARK: - Codable conformance with backward compatibility
extension ActionPoint: Codable {
    enum CodingKeys: String, CodingKey {
        case id, text, owner, done
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(owner, forKey: .owner)
        try container.encode(done, forKey: .done)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

/// Результат LLM-постобработки одной встречи. Ложится рядом с transcript.json.
struct MeetingInsights: Codable, Equatable {
    static let currentSchemaVersion = 1

    let meetingId: String
    let llmModel: String
    let generatedAt: Date
    let title: String
    let summary: String
    let actionPoints: [ActionPoint]
    var schemaVersion: Int? = nil

    static func encoded(_ insights: MeetingInsights) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(insights)
    }

    static func decoded(_ data: Data) throws -> MeetingInsights {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(MeetingInsights.self, from: data)
    }

    func write(to url: URL) throws { try Self.encoded(self).write(to: url, options: .atomic) }
}
