import Foundation
import os

/// При запуске: спасение встреч, оборванных крашем или выходом из приложения.
/// - `recording` — чиним WAV-заголовки, закрываем meta по фактической длительности → в очередь;
/// - `processing` — краш во время ASR, WAV целы → в очередь заново;
/// - `summarizing` — транскрипт готов, недоделан только LLM → статус ready, в очередь не отдаём.
enum StartupRescue {
    /// Возвращает папки к постановке в очередь `.process` (auto-конфиг), старые первыми.
    /// В очередь сам не ставит — это делает вызывающий код (тестируемость).
    static func run(root: URL = AppPaths.meetingsRoot) -> [URL] {
        var toProcess: [URL] = []
        for summary in MeetingLibrary.scan(root: root).sorted(by: { $0.id < $1.id }) {
            let dir = root.appendingPathComponent(summary.id, isDirectory: true)
            let metaURL = dir.appendingPathComponent("meta.json")
            switch summary.metaStatus {
            case .recording:
                guard let old = try? MeetingMeta.decoded(Data(contentsOf: metaURL)) else { continue }
                let micDur = WavRepair.repairIfNeeded(at: dir.appendingPathComponent("mic.wav"))?.durationSeconds ?? 0
                let sysDur = WavRepair.repairIfNeeded(at: dir.appendingPathComponent("system.wav"))?.durationSeconds ?? 0
                let duration = max(micDur, sysDur, old.durationSeconds)
                let meta = MeetingMeta(id: old.id, source: old.source,
                                       startedAt: old.startedAt,
                                       endedAt: old.startedAt.addingTimeInterval(TimeInterval(duration)),
                                       durationSeconds: duration,
                                       status: .recording, asrModel: old.asrModel,
                                       title: old.title, titleManual: old.titleManual, schemaVersion: old.schemaVersion)
                try? meta.write(to: metaURL)
                Log.pipeline.info("rescue: \(old.id, privacy: .public) recording → в очередь (\(duration) c)")
                toProcess.append(dir)
            case .processing:
                Log.pipeline.info("rescue: \(summary.id, privacy: .public) processing → в очередь")
                toProcess.append(dir)
            case .summarizing:
                guard var meta = try? MeetingMeta.decoded(Data(contentsOf: metaURL)) else { continue }
                meta.status = .ready
                try? meta.write(to: metaURL)
                Log.pipeline.info("rescue: \(summary.id, privacy: .public) summarizing→ready")
            default:
                continue
            }
        }
        return toProcess
    }
}
