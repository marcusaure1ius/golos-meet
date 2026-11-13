import Foundation
import Combine

/// Read-model встреч: сканирует каталог `meetings/`, декодирует `meta.json`,
/// вычисляет эффективный статус, лениво читает транскрипт по запросу деталей.
@MainActor
final class MeetingLibrary: ObservableObject {
    @Published private(set) var summaries: [MeetingSummary] = []
    private let root: URL
    private let searchIndex = MeetingSearchIndex()

    init(root: URL) { self.root = root }
    convenience init() { self.init(root: AppPaths.meetingsRoot) }

    func reload() {
        searchIndex.invalidate()
        summaries = MeetingLibrary.scan(root: root)
    }

    /// Поисковый текст встречи (через ленивый индекс; root — как у библиотеки).
    func searchText(for id: String) -> String { searchIndex.text(for: id, root: root) }

    /// Есть ли у встречи дорожка `base.<ext>` хотя бы в одном расширении.
    static func hasTrack(_ bases: [String], extensions exts: [String], in dir: URL) -> Bool {
        let fm = FileManager.default
        return bases.contains { base in
            exts.contains { fm.fileExists(atPath: dir.appendingPathComponent("\(base).\($0)").path) }
        }
    }

    /// Чистое сканирование каталога встреч (тестируется на временной папке).
    static func scan(root: URL) -> [MeetingSummary] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [MeetingSummary] = []
        for dir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let id = dir.lastPathComponent
            let meta = (try? Data(contentsOf: dir.appendingPathComponent("meta.json")))
                .flatMap { try? MeetingMeta.decoded($0) }
            // Аудио есть в несжатом (.wav) или сжатом архивном (.m4a, #83) виде.
            let hasAudio = MeetingLibrary.hasTrack(["mic", "system"], extensions: ["wav", "m4a"], in: dir)
            let hasTranscript = fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
            let hasInsights = fm.fileExists(atPath: dir.appendingPathComponent("insights.json").path)
            guard meta != nil || hasAudio || hasTranscript else { continue }
            let summary = MeetingSummary.make(folderId: id, meta: meta, hasAudio: hasAudio,
                                              hasTranscript: hasTranscript, hasInsights: hasInsights,
                                              hasArchivedAudio: meta?.archivedAudio == true)
            // Отброшенные (короче порога) не листим вовсе — папка на диске остаётся.
            guard summary.status != .discarded else { continue }
            result.append(summary)
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    /// Ленивая загрузка транскрипта встречи.
    func transcript(for id: String) -> Transcript? {
        let url = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    /// Ленивая загрузка инсайтов встречи.
    func insights(for id: String) -> MeetingInsights? {
        let url = root.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("insights.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MeetingInsights.decoded(data)
    }
}
