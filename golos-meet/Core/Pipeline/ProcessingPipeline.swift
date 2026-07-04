import Foundation
import os

struct PipelineConfig {
    var thresholdSeconds: Int = 300
    /// true (авто-режим): короткие удаляем. false (backfill): сохраняем и обрабатываем.
    var deleteShortAudio: Bool = true
}

/// Оркестрация пост-записи: порог → ASR обеих дорожек → merge → артефакты → (LLM) → статус.
final class ProcessingPipeline {
    private let asrFactory: () -> ASRClient
    private let config: PipelineConfig
    /// Идентификатор ASR-модели; пишется в meta.asrModel и шапку транскрипта.
    private let modelId: String
    private let insightsGenerator: InsightsGenerator?

    init(asrFactory: @escaping () -> ASRClient,
         config: PipelineConfig = .init(),
         modelId: String = "gigaam-v3",
         insightsGenerator: InsightsGenerator? = nil) {
        self.asrFactory = asrFactory
        self.config = config
        self.modelId = modelId
        self.insightsGenerator = insightsGenerator
    }

    func process(folder: URL) async {
        let metaURL = folder.appendingPathComponent("meta.json")
        guard var meta = try? MeetingMeta.decoded(Data(contentsOf: metaURL)) else {
            Log.pipeline.error("meta.json не прочитан: \(folder.lastPathComponent, privacy: .public)")
            return
        }

        // Короткая встреча в авто-режиме — выбросить.
        if meta.durationSeconds <= config.thresholdSeconds && config.deleteShortAudio {
            meta.status = .discarded
            do { try meta.write(to: metaURL) } catch { Log.pipeline.error("meta.write failed for \(meta.id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("mic.wav"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("system.wav"))
            Log.pipeline.info("\(meta.id, privacy: .public): discarded (<= порога, engine=\(self.modelId, privacy: .public))")
            return
        }

        Log.pipeline.info("processing \(meta.id, privacy: .public) engine=\(self.modelId, privacy: .public)")
        meta.status = .processing
        do { try meta.write(to: metaURL) } catch { Log.pipeline.error("meta.write failed for \(meta.id, privacy: .public): \(error.localizedDescription, privacy: .public)") }

        let asr = asrFactory()
        do {
            let me = try await transcribeIfExists(asr, folder.appendingPathComponent("mic.wav"))
            let participants = try await transcribeIfExists(asr, folder.appendingPathComponent("system.wav"))
            Log.pipeline.info("\(meta.id, privacy: .public): mic=\(me.count) сегм., system=\(participants.count) сегм.")
            let transcript = TranscriptMerger.merge(
                meetingId: meta.id, asrModel: modelId,
                me: me, participants: participants)
            let title = "Встреча \(meta.id)"
            try TranscriptMerger.renderJSON(transcript)
                .write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
            try Data(TranscriptMerger.renderMarkdown(transcript, title: title).utf8)
                .write(to: folder.appendingPathComponent("transcript.md"), options: .atomic)
            meta.asrModel = modelId
            // Освободить ASR ДО сетевого LLM-шага (не держать ~3 ГБ Whisper).
            if let local = asr as? LocalASR { await local.shutdown() }

            await runInsights(&meta, transcript: transcript, folder: folder, metaURL: metaURL)

            meta.status = .ready
            do { try meta.write(to: metaURL) } catch { Log.pipeline.error("meta.write failed for \(meta.id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            Log.pipeline.info("\(meta.id, privacy: .public): ready (\(transcript.segments.count) сегм., engine=\(self.modelId, privacy: .public))")
        } catch {
            meta.status = .failed
            do { try meta.write(to: metaURL) } catch { Log.pipeline.error("meta.write failed for \(meta.id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            Log.pipeline.error("\(meta.id, privacy: .public): failed (engine=\(self.modelId, privacy: .public)) — \(error.localizedDescription, privacy: .public)")
            if let local = asr as? LocalASR { await local.shutdown() }
        }
    }

    private func transcribeIfExists(_ asr: ASRClient, _ url: URL) async throws -> [TimedSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try await asr.transcribe(fileURL: url)
    }

    /// LLM-инсайты: пишет insights.json + meta.title. Ошибка не роняет встречу.
    private func runInsights(_ meta: inout MeetingMeta, transcript: Transcript,
                             folder: URL, metaURL: URL) async {
        guard let gen = insightsGenerator, !transcript.segments.isEmpty else { return }
        meta.status = .summarizing
        let meetingId = meta.id   // копия, чтобы не захватывать inout в escaping-замыкании
        do { try meta.write(to: metaURL) } catch { Log.pipeline.error("meta.write failed for \(meetingId, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        do {
            let insights = try await gen.generate(from: transcript, meetingId: meetingId)
            try insights.write(to: folder.appendingPathComponent("insights.json"))
            if meta.titleManual != true { meta.title = insights.title }
            Log.llm.info("\(meetingId, privacy: .public): insights ok (\(insights.actionPoints.count) action points)")
        } catch {
            Log.llm.error("\(meetingId, privacy: .public): insights failed — \(error.localizedDescription, privacy: .public)")
        }
    }
}
