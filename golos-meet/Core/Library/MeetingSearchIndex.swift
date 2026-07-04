import Foundation

/// Ленивый кеш поискового текста встреч: заголовок + insights + транскрипт,
/// нижний регистр. Строится по запросу, инвалидируется на reload библиотеки.
@MainActor
final class MeetingSearchIndex {
    private var cache: [String: String] = [:]

    func invalidate() { cache.removeAll() }

    /// Объединённый поисковый текст встречи (кешируется по id).
    func text(for id: String, root: URL = AppPaths.meetingsRoot) -> String {
        if let cached = cache[id] { return cached }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let meta = (try? Data(contentsOf: dir.appendingPathComponent("meta.json")))
            .flatMap { try? MeetingMeta.decoded($0) }
        let insights = (try? Data(contentsOf: dir.appendingPathComponent("insights.json")))
            .flatMap { try? MeetingInsights.decoded($0) }
        let transcript = (try? Data(contentsOf: dir.appendingPathComponent("transcript.json")))
            .flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
        let text = Self.buildText(title: meta?.title, insights: insights, transcript: transcript)
        cache[id] = text
        return text
    }

    /// Чистая сборка текста (тестируется без диска).
    static func buildText(title: String?, insights: MeetingInsights?, transcript: Transcript?) -> String {
        var parts: [String] = []
        if let title { parts.append(title) }
        if let insights {
            parts.append(insights.title)
            parts.append(insights.summary)
            parts.append(contentsOf: insights.actionPoints.map(\.text))
        }
        if let transcript {
            parts.append(contentsOf: transcript.segments.map(\.text))
        }
        return parts.joined(separator: " ").lowercased()
    }
}
