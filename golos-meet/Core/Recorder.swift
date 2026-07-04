import Foundation
import os

/// Общий контракт дорожки захвата: стартует, пишет Int16 PCM в переданный writer, останавливается.
protocol AudioTrack {
    func start(into writer: WavWriter) throws
    func stop()
}

/// Метаданные одной встречи, ложатся рядом с дорожками как `meta.json`.
struct MeetingMeta: Codable, Equatable {
    /// Текущая версия схемы meta.json. Растёт при несовместимых изменениях.
    static let currentSchemaVersion = 1

    let id: String
    let source: String
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
    var status: MeetingStatus?
    var asrModel: String?
    /// Заголовок встречи для UI (placeholder при старте, позже уточняется).
    var title: String? = nil
    /// Заголовок задан вручную пользователем — LLM его не перезаписывает.
    var titleManual: Bool? = nil
    /// Версия схемы; nil у старых meta, записанных до введения поля.
    var schemaVersion: Int? = nil

    static func encoded(_ meta: MeetingMeta) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(meta)
    }

    static func decoded(_ data: Data) throws -> MeetingMeta {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(MeetingMeta.self, from: data)
    }

    func write(to url: URL) throws { try Self.encoded(self).write(to: url, options: .atomic) }
}

/// Глобальная константа версии схемы meta.json (см. `MeetingMeta.currentSchemaVersion`).
let currentMetaSchemaVersion = MeetingMeta.currentSchemaVersion

/// Оркестрация записи: по `meetingStarted` создаёт папку встречи, поднимает две дорожки
/// (микрофон + системный звук) в свои WavWriter'ы; по `meetingEnded` останавливает,
/// финализирует оба WAV и пишет `meta.json`.
@MainActor
final class Recorder: MeetingDetectorDelegate {
    private struct Active {
        let folder: MeetingFolder
        let mic: WavWriter
        let system: WavWriter
        let micTrack: AudioTrack
        let sysTrack: AudioTrack
        let startedAt: Date
    }

    private var active: Active?

    // Инъекции (тесты); дефолты — прод-поведение.
    private let enqueueProcessing: (String, URL) -> Void
    private let makeMicTrack: () -> AudioTrack
    private let makeSysTrack: () -> AudioTrack
    private let makeFolder: (Date, String) -> MeetingFolder

    init(enqueueProcessing: ((String, URL) -> Void)? = nil,
         makeMicTrack: @escaping () -> AudioTrack = { MicCaptureTrack() },
         makeSysTrack: @escaping () -> AudioTrack = { SystemAudioCaptureTrack() },
         makeFolder: @escaping (Date, String) -> MeetingFolder = { MeetingFolder.make(startedAt: $0, source: $1) }) {
        self.enqueueProcessing = enqueueProcessing ?? { id, folder in
            MeetingProcessor.shared.enqueue(.process(deleteShortAudio: true), id: id, folder: folder)
        }
        self.makeMicTrack = makeMicTrack
        self.makeSysTrack = makeSysTrack
        self.makeFolder = makeFolder
    }

    var isRecording: Bool { active != nil }

    /// Placeholder-заголовок для UI: «Встреча HH:mm» в локальном времени.
    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f
    }()
    private static func placeholderTitle(for date: Date) -> String {
        "Встреча \(titleFormatter.string(from: date))"
    }

    func meetingStarted(at date: Date, manual: Bool) {
        guard active == nil else { return }
        do {
            let folder = makeFolder(date, "kontur.talk")
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            // Пишем meta.json сразу: краш во время записи оставит на диске
            // восстановимую запись со status:.recording (вместо пустоты).
            let meta = MeetingMeta(id: folder.id, source: folder.source,
                                   startedAt: date, endedAt: date,
                                   durationSeconds: 0,
                                   status: .recording, asrModel: nil,
                                   title: Self.placeholderTitle(for: date),
                                   schemaVersion: currentMetaSchemaVersion)
            do {
                try meta.write(to: folder.url.appendingPathComponent("meta.json"))
            } catch {
                Log.recorder.error("meta.json (старт) не записан: \(error.localizedDescription, privacy: .public)")
            }
            let mic = try WavWriter(url: folder.url.appendingPathComponent("mic.wav"))
            let system = try WavWriter(url: folder.url.appendingPathComponent("system.wav"))
            let micTrack = makeMicTrack()
            let sysTrack = makeSysTrack()
            try micTrack.start(into: mic)
            try sysTrack.start(into: system)
            active = Active(folder: folder, mic: mic, system: system,
                            micTrack: micTrack, sysTrack: sysTrack, startedAt: date)
            RecordingState.shared.begin(id: folder.id, startedAt: date, isManual: manual)
            Log.recorder.info("запись начата: \(folder.id, privacy: .public)")
        } catch {
            Log.recorder.error("старт записи провалился: \(error.localizedDescription, privacy: .public)")
        }
    }

    func meetingEnded(at date: Date) {
        guard active != nil else { return }
        Task {
            guard let folder = await finalizeActive(endedAt: date) else { return }
            enqueueProcessing(folder.id, folder.url)
        }
    }

    /// Останавливает дорожки, финализирует WAV, закрывает meta реальной длительностью
    /// (статус остаётся .recording — дальше статусы ведёт пайплайн). Идемпотентен:
    /// повторный вызов (terminate вслед за meetingEnded) возвращает nil.
    @discardableResult
    func finalizeActive(endedAt: Date) async -> MeetingFolder? {
        guard let a = active else { return nil }
        active = nil
        RecordingState.shared.end()
        a.micTrack.stop()
        a.sysTrack.stop()
        do { try await a.mic.finalize() } catch {
            Log.recorder.error("финализация mic.wav провалилась: \(error.localizedDescription, privacy: .public)")
        }
        do { try await a.system.finalize() } catch {
            Log.recorder.error("финализация system.wav провалилась: \(error.localizedDescription, privacy: .public)")
        }
        let meta = MeetingMeta(id: a.folder.id, source: a.folder.source,
                               startedAt: a.startedAt, endedAt: endedAt,
                               durationSeconds: Int(endedAt.timeIntervalSince(a.startedAt)),
                               status: .recording, asrModel: nil,
                               title: Self.placeholderTitle(for: a.startedAt),
                               schemaVersion: currentMetaSchemaVersion)
        do {
            try meta.write(to: a.folder.url.appendingPathComponent("meta.json"))
        } catch {
            Log.recorder.error("meta.json (стоп) не записан: \(error.localizedDescription, privacy: .public)")
        }
        Log.recorder.info("запись завершена: \(a.folder.id, privacy: .public)")
        return a.folder
    }
}
