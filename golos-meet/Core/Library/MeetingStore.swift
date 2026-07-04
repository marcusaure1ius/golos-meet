import Foundation
import os

/// Мутации встречи на диске: удаление папки, переименование, отметка action point.
/// Отдельно от read-model `MeetingLibrary` (тот только читает). После вызова
/// вызывающий сам делает `library.reload()`.
@MainActor
enum MeetingStore {
    /// Удаляет папку встречи целиком. Несуществующая папка — не ошибка.
    static func delete(id: String, root: URL = AppPaths.meetingsRoot) throws {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
        Log.pipeline.info("delete: \(id, privacy: .public)")
    }

    /// Ставит ручной заголовок и флаг `titleManual` (LLM его больше не трогает).
    static func rename(id: String, title: String, root: URL = AppPaths.meetingsRoot) throws {
        let metaURL = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("meta.json")
        var meta = try MeetingMeta.decoded(Data(contentsOf: metaURL))
        meta.title = title
        meta.titleManual = true
        try meta.write(to: metaURL)
    }

    /// Тоггл выполнения одного action point в insights.json (по id).
    static func setActionPointDone(id: String, actionPointId: UUID, done: Bool,
                                   root: URL = AppPaths.meetingsRoot) throws {
        let url = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("insights.json")
        var insights = try MeetingInsights.decoded(Data(contentsOf: url))
        var points = insights.actionPoints
        guard let idx = points.firstIndex(where: { $0.id == actionPointId }) else { return }
        points[idx].done = done
        insights = MeetingInsights(meetingId: insights.meetingId, llmModel: insights.llmModel,
                                   generatedAt: insights.generatedAt, title: insights.title,
                                   summary: insights.summary, actionPoints: points,
                                   schemaVersion: insights.schemaVersion)
        try insights.write(to: url)
    }
}
