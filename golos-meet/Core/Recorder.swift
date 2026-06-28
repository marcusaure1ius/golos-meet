import Foundation
import os

/// Общий контракт дорожки захвата: стартует, пишет Int16 PCM в переданный writer, останавливается.
protocol AudioTrack {
    func start(into writer: WavWriter) throws
    func stop()
}

/// Метаданные одной встречи, ложатся рядом с дорожками как `meta.json`.
struct MeetingMeta: Codable, Equatable {
    let id: String
    let source: String
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
    var status: MeetingStatus?
    var asrModel: String?

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

    func write(to url: URL) throws { try Self.encoded(self).write(to: url) }
}

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

    func meetingStarted(at date: Date) {
        guard active == nil else { return }
        do {
            let folder = MeetingFolder.make(startedAt: date, source: "kontur.talk")
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            let mic = try WavWriter(url: folder.url.appendingPathComponent("mic.wav"))
            let system = try WavWriter(url: folder.url.appendingPathComponent("system.wav"))
            let micTrack = MicCaptureTrack()
            let sysTrack = SystemAudioCaptureTrack()
            try micTrack.start(into: mic)
            try sysTrack.start(into: system)
            active = Active(folder: folder, mic: mic, system: system,
                            micTrack: micTrack, sysTrack: sysTrack, startedAt: date)
            Log.recorder.info("запись начата: \(folder.id, privacy: .public)")
        } catch {
            Log.recorder.error("старт записи провалился: \(error.localizedDescription, privacy: .public)")
        }
    }

    func meetingEnded(at date: Date) {
        guard let a = active else { return }
        active = nil
        a.micTrack.stop()
        a.sysTrack.stop()
        Task {
            try? await a.mic.finalize()
            try? await a.system.finalize()
            let meta = MeetingMeta(id: a.folder.id, source: a.folder.source,
                                   startedAt: a.startedAt, endedAt: date,
                                   durationSeconds: Int(date.timeIntervalSince(a.startedAt)),
                                   status: .recording, asrModel: nil)
            try? meta.write(to: a.folder.url.appendingPathComponent("meta.json"))
            Log.recorder.info("запись завершена: \(a.folder.id, privacy: .public)")
            let pipeline = ProcessingPipeline(asrFactory: {
                LocalASR.forChoice(ASRSettings.current)
            })
            await pipeline.process(folder: a.folder.url)
        }
    }
}
