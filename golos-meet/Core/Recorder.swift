import Foundation
import os

/// Общий контракт дорожки захвата: стартует, пишет Int16 PCM в переданный writer, останавливается.
@MainActor
protocol AudioTrack: AnyObject {
    var onFailure: (() -> Void)? { get set }
    /// Returns only after the capture backend is ready. Silence is valid audio.
    func start(into writer: WavWriter) async throws
    /// Must stop accepting buffers and drain queued writes before returning.
    func stop() async
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
    /// Manual, interrupted and failed capture must survive the short-audio filter.
    var preserveAudio: Bool? = nil

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
    private final class Active {
        let folder: MeetingFolder
        let mic: WavWriter
        let system: WavWriter
        let micTrack: AudioTrack
        let sysTrack: AudioTrack
        let startedAt: Date
        let manual: Bool
        var failed = false
        var ending = false
        var startTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        init(folder: MeetingFolder, mic: WavWriter, system: WavWriter,
             micTrack: AudioTrack, sysTrack: AudioTrack, startedAt: Date, manual: Bool) {
            self.folder = folder; self.mic = mic; self.system = system
            self.micTrack = micTrack; self.sysTrack = sysTrack
            self.startedAt = startedAt; self.manual = manual
        }
    }

    private var active: Active?
    private var finalization: Task<MeetingFolder?, Never>?
    var onCaptureFailure: (() -> Void)?

    private let enqueueProcessing: (String, URL) -> Void
    private let makeMicTrack: @MainActor () -> AudioTrack
    private let makeSysTrack: @MainActor () -> AudioTrack
    private let makeFolder: @MainActor (Date, String) -> MeetingFolder
    private let state: RecordingState
    private let startupTimeout: Duration

    init(enqueueProcessing: ((String, URL) -> Void)? = nil,
         makeMicTrack: (@MainActor () -> AudioTrack)? = nil,
         makeSysTrack: (@MainActor () -> AudioTrack)? = nil,
         makeFolder: (@MainActor (Date, String) -> MeetingFolder)? = nil,
         state: RecordingState? = nil,
         startupTimeout: Duration = .seconds(20)) {
        self.enqueueProcessing = enqueueProcessing ?? { id, folder in
            MeetingProcessor.shared.enqueue(.process(deleteShortAudio: true), id: id, folder: folder)
        }
        self.makeMicTrack = makeMicTrack ?? { MicCaptureTrack() }
        self.makeSysTrack = makeSysTrack ?? { SystemAudioCaptureTrack() }
        self.makeFolder = makeFolder ?? { MeetingFolder.make(startedAt: $0, source: $1) }
        self.state = state ?? .shared
        self.startupTimeout = startupTimeout
    }

    /// Also true while starting/stopping: termination must wait for cleanup.
    var isRecording: Bool { active != nil || finalization != nil }

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

    /// Acceptance is synchronous for MeetingDetector; success is published only
    /// after both asynchronous track starts complete.
    func meetingStarted(at date: Date, manual: Bool) -> Bool {
        guard !isRecording else { return false }
        do {
            let folder = makeFolder(date, "kontur.talk")
            try FileManager.default.createDirectory(at: folder.url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: false)
            let meta = MeetingMeta(id: folder.id, source: folder.source,
                                   startedAt: date, endedAt: date, durationSeconds: 0,
                                   status: .recording, asrModel: nil,
                                   title: Self.placeholderTitle(for: date),
                                   schemaVersion: currentMetaSchemaVersion, preserveAudio: true)
            // Do not capture when the recovery metadata cannot be persisted.
            try meta.write(to: folder.url.appendingPathComponent("meta.json"))
            let mic = try WavWriter(url: folder.url.appendingPathComponent("mic.wav"))
            let system = try WavWriter(url: folder.url.appendingPathComponent("system.wav"))
            let a = Active(folder: folder, mic: mic, system: system,
                           micTrack: makeMicTrack(), sysTrack: makeSysTrack(), startedAt: date, manual: manual)
            active = a
            state.prepare()
            a.micTrack.onFailure = { [weak self, weak a] in
                guard let a else { return }
                self?.captureFailed(a, track: .microphone)
            }
            a.sysTrack.onFailure = { [weak self, weak a] in
                guard let a else { return }
                self?.captureFailed(a, track: .system)
            }
            a.startTask = Task { [weak self] in
                guard let self else { return }
                await self.startTracks(a)
            }
            a.timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: self?.startupTimeout ?? .seconds(20)) }
                catch { return }
                guard !Task.isCancelled, self?.state.phase == .starting else { return }
                self?.captureFailed(a, track: nil)
            }
            return true
        } catch {
            state.fail("Не удалось подготовить файлы записи. Проверьте свободное место и доступ к папке встреч.")
            return false
        }
    }

    private func startTracks(_ a: Active) async {
        guard active === a, !a.ending, !a.failed, !Task.isCancelled else { return }
        var track = RecordingState.Track.microphone
        do {
            try await a.micTrack.start(into: a.mic)
            try Task.checkCancellation()
            guard active === a, !a.ending, !a.failed else { return }
            state.ready(.microphone)
            track = .system
            try await a.sysTrack.start(into: a.system)
            try Task.checkCancellation()
            guard active === a, !a.ending, !a.failed else { return }
            state.ready(.system)
            a.timeoutTask?.cancel()
            state.begin(id: a.folder.id, startedAt: a.startedAt, isManual: a.manual)
            Log.recorder.info("Обе дорожки захвата готовы")
        } catch {
            guard active === a, !a.ending else { return }
            captureFailed(a, track: track)
        }
    }

    private func captureFailed(_ a: Active, track: RecordingState.Track?) {
        guard active === a, !a.failed else { return }
        a.failed = true
        Log.recorder.error("Ошибка дорожки захвата")
        state.trackFailed(track)
        if a.ending { return }
        state.stopping()
        onCaptureFailure?()
        Task { await finalizeActive(endedAt: Date()) }
    }

    func meetingEnded(at date: Date) {
        guard let active else { return }
        active.startTask?.cancel()
        state.stopping()
        Task {
            guard let folder = await finalizeActive(endedAt: date),
                  let meta = try? MeetingMeta.decoded(Data(contentsOf: folder.url.appendingPathComponent("meta.json"))),
                  meta.status != .failed else { return }
            enqueueProcessing(folder.id, folder.url)
        }
    }

    /// Coalesces concurrent termination/stop. Later callers await cleanup but do
    /// not receive a second folder to enqueue. New starts wait until all drains end.
    @discardableResult
    func finalizeActive(endedAt: Date) async -> MeetingFolder? {
        if let finalization { _ = await finalization.value; return nil }
        guard let a = active else { return nil }
        a.ending = true
        a.timeoutTask?.cancel()
        a.startTask?.cancel()
        state.stopping()
        let task = Task { await self.finish(a, endedAt: endedAt) }
        finalization = task
        let folder = await task.value
        active = nil
        finalization = nil
        if a.failed {
            state.fail("Запись прервана. Проверьте разрешения и свободное место.")
        } else { state.end() }
        Log.recorder.info("Финализация захвата завершена; ошибка: \(a.failed)")
        return folder
    }

    private func finish(_ a: Active, endedAt: Date) async -> MeetingFolder? {
        // Stop during async start, then drain a possible late completion once more.
        await a.micTrack.stop()
        state.stopped(.microphone)
        await a.sysTrack.stop()
        state.stopped(.system)
        await a.startTask?.value
        await a.micTrack.stop()
        await a.sysTrack.stop()
        a.micTrack.onFailure = nil
        a.sysTrack.onFailure = nil
        do { try await a.mic.finalize() } catch { a.failed = true }
        do { try await a.system.finalize() } catch { a.failed = true }
        let current = try? MeetingMeta.decoded(Data(contentsOf: a.folder.url.appendingPathComponent("meta.json")))
        let meta = MeetingMeta(id: a.folder.id, source: a.folder.source,
                               startedAt: a.startedAt, endedAt: max(endedAt, a.startedAt),
                               durationSeconds: max(0, Int(endedAt.timeIntervalSince(a.startedAt))),
                               status: a.failed ? .failed : .recording, asrModel: nil,
                               title: current?.title ?? Self.placeholderTitle(for: a.startedAt),
                               titleManual: current?.titleManual, schemaVersion: currentMetaSchemaVersion,
                               preserveAudio: a.manual || a.failed || state.live == nil)
        do { try meta.write(to: a.folder.url.appendingPathComponent("meta.json")) }
        catch {
            a.failed = true
            // Original start metadata preserves audio for startup recovery.
            return nil
        }
        return a.folder
    }
}
