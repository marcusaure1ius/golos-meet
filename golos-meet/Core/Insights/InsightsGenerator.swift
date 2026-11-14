// golos-meet/Core/Insights/InsightsGenerator.swift
import Foundation

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
    /// Пункты прогоняются через `sanitizePoints`: модели (наблюдалось на
    /// DeepSeek/qwen) дегенерируют в циклические повторы одной мысли
    /// (issue #93), поэтому парсер не доверяет «сырому» списку.
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
            return (title, summary, sanitizePoints(points))
        }
        if let r = decode(Substring(raw)) { return r }
        // фолбэк: вырезать первый сбалансированный {…}
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close
        else { return nil }
        return decode(raw[open...close])
    }

    // MARK: - Пост-фильтр дегенеративных повторов (issue #93)

    /// Лимиты пункта. Синхронизированы с инструкциями `InsightsPrompt.system`
    /// (максимум 5 пунктов, 1–2 предложения на пункт) — промпт уговаривает,
    /// фильтр гарантирует.
    static let maxPoints = 5
    static let maxSentencesPerPoint = 4
    static let maxPointLength = 600          // бюджет символов на предложения
    static let hardPointCap = 800            // жёсткий потолок на весь пункт
    /// Порог нормализованного сходства (коэффициент Сёренсена–Дайса по
    /// «стеммированным» токенам), выше которого тексты считаются дублями.
    static let similarityThreshold = 0.85

    /// Пост-фильтр списка пунктов:
    /// 1) внутри пункта вырезаются повторяющиеся/почти одинаковые предложения
    ///    и лишняя длина (дегенерация «один пункт → 15 повторов»);
    /// 2) пункты, дублирующие друг друга по нормализованному сходству,
    ///    схлопываются в первый;
    /// 3) остаётся не более `maxPoints` пунктов.
    /// Порядок и owner сохраняются; title/summary не трогаются.
    static func sanitizePoints(_ points: [(String, String?)]) -> [(String, String?)] {
        var result: [(String, String?)] = []
        var tokens: [Set<String>] = []
        for (text, owner) in points {
            let cleaned = trimPointRepeats(text)
            guard !cleaned.isEmpty else { continue }
            let key = contentTokens(cleaned)
            if tokens.contains(where: { similarity($0, key) >= similarityThreshold }) { continue }
            result.append((cleaned, owner))
            tokens.append(key)
            if result.count == maxPoints { break }
        }
        return result
    }

    /// Обрезка дегенеративных повторов внутри одного пункта: оставляет первые
    /// уникальные предложения в пределах лимитов длины.
    static func trimPointRepeats(_ text: String) -> String {
        var kept: [String] = []
        var keptTokens: [Set<String>] = []
        var length = 0
        for sentence in splitSentences(text) {
            let isFirst = kept.isEmpty
            // Первый абзац-предложение оставляем всегда; дальше — только в бюджет.
            if !isFirst && (kept.count >= maxSentencesPerPoint || length + sentence.count > maxPointLength) {
                break
            }
            let key = contentTokens(sentence)
            if keptTokens.contains(where: { similarity($0, key) >= similarityThreshold }) { continue }
            kept.append(sentence)
            keptTokens.append(key)
            length += sentence.count + 1
        }
        var joined = kept.joined(separator: " ")
        if joined.count > hardPointCap {
            joined = String(joined.prefix(hardPointCap - 1)) + "…"
        }
        return joined
    }

    /// Разбивка на предложения: разделитель — «.!?…» плюс пробел/перевод строки.
    /// Пунктуация остаётся внутри предложения.
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var pendingTerminator = false
        for ch in text {
            if ".!?…".contains(ch) {
                current.append(ch)
                pendingTerminator = true
                continue
            }
            if pendingTerminator, ch.isWhitespace {
                let flushed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !flushed.isEmpty { sentences.append(flushed) }
                current = ""
                pendingTerminator = false
                continue
            }
            pendingTerminator = false
            current.append(ch)
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// Сходство двух наборов токенов: Сёренсен–Дайс, 1.0 у идентичных.
    /// Пустые наборы (предложения без содержательных слов) считаются дублями
    /// друг друга и не похожими на осмысленные предложения.
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty || b.isEmpty { return (a.isEmpty && b.isEmpty) ? 1.0 : 0.0 }
        let inter = a.intersection(b).count
        return Double(2 * inter) / Double(a.count + b.count)
    }

    /// «Стеммированные» содержательные токены: нижний регистр, без служебных
    /// слов и коротких обрывков, усечение до префикса 6 символов сглаживает
    /// русские падежные окончания («продуктов»/«продукты» → «продукт»).
    static let stopwords: Set<String> = [
        "было", "быть", "будет", "если", "чтобы", "когда", "который", "которая",
        "этого", "это", "как", "все", "весь", "она", "они", "него", "мне",
        "нам", "нас", "вам", "вас", "для", "при", "или", "про", "через", "между",
        "только", "также", "очень", "уже", "ещё", "там", "так", "тут", "вот",
    ]

    static func contentTokens(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let w = String(word)
            if w.count > 2 && !stopwords.contains(w) {
                tokens.insert(String(w.prefix(6)))
            }
        }
        return tokens
    }
}
