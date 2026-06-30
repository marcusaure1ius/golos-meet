import Foundation

/// Один пункт действий из встречи.
struct ActionPoint: Codable, Equatable, Identifiable {
    let id: UUID                 // генерится в Swift при разборе ответа LLM; для SwiftUI
    let text: String
    var owner: String? = nil     // ответственный, если выделен (nil — норма)
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
