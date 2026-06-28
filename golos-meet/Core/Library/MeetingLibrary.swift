import Foundation
import Combine

/// Read-model встреч: сканирует каталог `meetings/`, декодирует `meta.json`,
/// вычисляет эффективный статус, лениво читает транскрипт по запросу деталей.
@MainActor
final class MeetingLibrary: ObservableObject {
    @Published private(set) var summaries: [MeetingSummary] = []
    private let root: URL

    /// Инициализатор с явным корнем (для тестов). Без аргумента — используется `AppPaths.meetingsRoot`.
    init(root: URL? = nil) { self.root = root ?? AppPaths.meetingsRoot }

    func reload() { summaries = MeetingLibrary.scan(root: root) }

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
            let hasAudio = fm.fileExists(atPath: dir.appendingPathComponent("mic.wav").path)
                        || fm.fileExists(atPath: dir.appendingPathComponent("system.wav").path)
            let hasTranscript = fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
            result.append(MeetingSummary.make(folderId: id, meta: meta, hasAudio: hasAudio, hasTranscript: hasTranscript))
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    /// Ленивая загрузка транскрипта встречи.
    func transcript(for id: String) -> Transcript? {
        let url = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }
}
