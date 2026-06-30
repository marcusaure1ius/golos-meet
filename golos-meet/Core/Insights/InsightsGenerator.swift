// golos-meet/Core/Insights/InsightsGenerator.swift
import Foundation

/// Абстракция над транспортом — для тестируемости генератора.
protocol ChatCompleter {
    // nonisolated: совпадает с OpenRouterClient.complete (nonisolated).
    // Необходимо при SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, иначе
    // OpenRouterClient не удовлетворяет требованию (@MainActor vs nonisolated).
    nonisolated func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String
}

extension OpenRouterClient: ChatCompleter {}

struct InsightsGenerator {
    let client: ChatCompleter
    let model: String

    /// Transcript → MeetingInsights. Бросает LLMError при пустом транскрипте,
    /// сетевой ошибке или неразборчивом ответе.
    func generate(from transcript: Transcript, meetingId: String, now: Date = Date()) async throws -> MeetingInsights {
        guard !transcript.segments.isEmpty else { throw LLMError.emptyResponse }

        let messages = [
            ChatMessage(role: "system", content: InsightsPrompt.system),
            ChatMessage(role: "user", content: InsightsPrompt.dialog(from: transcript)),
        ]
        let raw = try await client.complete(model: model, messages: messages,
                                            responseFormat: InsightsPrompt.responseFormat)
        guard let parsed = Self.parse(raw) else { throw LLMError.decode }

        return MeetingInsights(
            meetingId: meetingId,
            llmModel: model,
            generatedAt: now,
            title: parsed.title,
            summary: parsed.summary,
            actionPoints: parsed.points.map { ActionPoint(id: UUID(), text: $0.0, owner: $0.1) },
            schemaVersion: MeetingInsights.currentSchemaVersion)
    }

    /// Разбор ответа: сперва как чистый JSON, затем фолбэк — первый блок {…}.
    static func parse(_ raw: String) -> (title: String, summary: String, points: [(String, String?)])? {
        func decode(_ s: Substring) -> (String, String, [(String, String?)])? {
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = obj["title"] as? String,
                  let summary = obj["summary"] as? String else { return nil }
            // Модель не всегда соблюдает имя поля из json_schema: qwen через
            // OpenRouter возвращает snake_case `action_points`. Принимаем оба.
            let rawPoints = (obj["actionPoints"] ?? obj["action_points"]) as? [[String: Any]] ?? []
            let points: [(String, String?)] = rawPoints.compactMap { p in
                // Имя поля тоже не из схемы: qwen отдаёт `task` вместо `text`.
                guard let text = (p["text"] ?? p["task"]) as? String else { return nil }
                return (text, p["owner"] as? String)   // null/отсутствие → nil
            }
            return (title, summary, points)
        }
        if let r = decode(Substring(raw)) { return r }
        // фолбэк: вырезать первый сбалансированный {…}
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close
        else { return nil }
        return decode(raw[open...close])
    }
}
