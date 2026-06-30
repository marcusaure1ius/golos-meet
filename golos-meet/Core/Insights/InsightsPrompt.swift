import Foundation

/// Дефолтный системный промпт, рендер диалога и JSON-schema ответа.
/// Вынесено отдельно — позже оверрайдабельно из настроек.
enum InsightsPrompt {
    static let system = """
    Ты — ассистент, который обрабатывает расшифровку рабочей встречи на русском языке.
    На входе — диалог в формате «спикер: реплика», где «я» — владелец записи, \
    «участники» — собеседники. Сформируй:
    1) краткий осмысленный заголовок встречи (3–7 слов, без даты),
    2) связный конспект (summary) в несколько абзацев,
    3) список action points — конкретные задачи/договорённости; если в реплике \
    явно назван ответственный, укажи его в поле owner, иначе owner = null.
    Верни СТРОГО JSON по заданной схеме, без пояснений и без markdown-обёртки.
    Отвечай на русском.
    """

    /// «спикер: текст» по сегментам, без таймкодов (для LLM они шум).
    static func dialog(from transcript: Transcript) -> String {
        transcript.segments
            .map { "\($0.speaker.displayName): \($0.text)" }
            .joined(separator: "\n")
    }

    /// json_schema для response_format: { title, summary, actionPoints:[{text, owner}] }.
    static let responseFormat: ResponseFormat = .jsonSchema(name: "meeting_insights", schema:
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("title"), .string("summary"), .string("actionPoints")]),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "summary": .object(["type": .string("string")]),
                "actionPoints": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "required": .array([.string("text")]),
                        "properties": .object([
                            "text": .object(["type": .string("string")]),
                            "owner": .object(["type": .array([.string("string"), .string("null")])]),
                        ]),
                    ]),
                ]),
            ]),
        ]))
}
