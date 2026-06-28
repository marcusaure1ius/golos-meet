import Foundation
import os

struct PipelineConfig {
    var thresholdSeconds: Int = 300
    /// true (авто-режим): короткие удаляем. false (backfill): сохраняем и обрабатываем.
    var deleteShortAudio: Bool = true
}

/// Оркестрация пост-записи: порог → ASR обеих дорожек → merge → артефакты → статус.
final class ProcessingPipeline {
    private let asrFactory: () -> ASRClient
    private let config: PipelineConfig

    init(asrFactory: @escaping () -> ASRClient, config: PipelineConfig = .init()) {
        self.asrFactory = asrFactory
        self.config = config
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
            try? meta.write(to: metaURL)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("mic.wav"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("system.wav"))
            Log.pipeline.info("\(meta.id, privacy: .public): discarded (<= порога)")
            return
        }

        meta.status = .processing
        try? meta.write(to: metaURL)

        let asr = asrFactory()
        do {
            let me = try await transcribeIfExists(asr, folder.appendingPathComponent("mic.wav"))
            let participants = try await transcribeIfExists(asr, folder.appendingPathComponent("system.wav"))
            let transcript = TranscriptMerger.merge(
                meetingId: meta.id, asrModel: ModelDescriptor.asrModelId,
                me: me, participants: participants)
            let title = "Встреча \(meta.id)"
            try TranscriptMerger.renderJSON(transcript)
                .write(to: folder.appendingPathComponent("transcript.json"))
            try Data(TranscriptMerger.renderMarkdown(transcript, title: title).utf8)
                .write(to: folder.appendingPathComponent("transcript.md"))
            meta.asrModel = ModelDescriptor.asrModelId
            meta.status = .ready
            try? meta.write(to: metaURL)
            Log.pipeline.info("\(meta.id, privacy: .public): ready (\(transcript.segments.count) сегм.)")
        } catch {
            meta.status = .failed
            try? meta.write(to: metaURL)
            Log.pipeline.error("\(meta.id, privacy: .public): failed — \(error.localizedDescription, privacy: .public)")
        }
        if let local = asr as? LocalASR { await local.shutdown() }
    }

    private func transcribeIfExists(_ asr: ASRClient, _ url: URL) async throws -> [TimedSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try await asr.transcribe(fileURL: url)
    }
}
