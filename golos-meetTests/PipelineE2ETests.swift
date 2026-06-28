import Testing
import Foundation
@testable import golos_meet

/// Интеграционный тест: реальный прогон полного пайплайна
/// ProcessingPipeline → LocalASR → sidecar golos-asr → GigaAM → TranscriptMerger → артефакты.
///
/// Тест GATED: пропускается (pass-by-return), если не заданы env-переменные:
///   GOLOS_MEET_ASR_BIN   — путь к release-бинарю sidecar (asr/target/release/golos-asr)
///   GOLOS_MEET_GIGAAM_DIR — путь к каталогу модели GigaAM CTC (model.onnx + vocab.txt)
///
/// Опционально:
///   GOLOS_MEET_E2E_SRC — каталог записи-источника (mic.wav + system.wav);
///                         дефолт: ~/Library/Application Support/golos-meet/meetings/2026-06-23_09-44-58

@Suite struct PipelineE2ETests {

    @Test func realGigaAMPipelineProducesTranscript() async throws {
        let env = ProcessInfo.processInfo.environment

        // Gate 1: env vars must be set and non-empty
        guard let asrBin = env["GOLOS_MEET_ASR_BIN"], !asrBin.isEmpty else {
            print("[PipelineE2ETests] GOLOS_MEET_ASR_BIN не задан — тест пропущен.")
            return
        }
        guard let gigaamDir = env["GOLOS_MEET_GIGAAM_DIR"], !gigaamDir.isEmpty else {
            print("[PipelineE2ETests] GOLOS_MEET_GIGAAM_DIR не задан — тест пропущен.")
            return
        }

        // Gate 2: referenced files must exist on this machine (skip gracefully on CI/other hosts)
        guard FileManager.default.fileExists(atPath: asrBin) else {
            print("[PipelineE2ETests] sidecar binary не найден: \(asrBin) — тест пропущен.")
            return
        }
        guard FileManager.default.fileExists(atPath: gigaamDir) else {
            print("[PipelineE2ETests] модель GigaAM не найдена: \(gigaamDir) — тест пропущен.")
            return
        }

        // Каталог записи-источника (содержит mic.wav + system.wav с реальной речью)
        let srcDefault = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/golos-meet/meetings/2026-06-23_09-44-58")
        let srcDir = env["GOLOS_MEET_E2E_SRC"].map { URL(fileURLWithPath: $0) } ?? srcDefault

        // Временная папка встречи
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Копируем аудио-дорожки
        try FileManager.default.copyItem(
            at: srcDir.appendingPathComponent("mic.wav"),
            to: tempDir.appendingPathComponent("mic.wav"))
        try FileManager.default.copyItem(
            at: srcDir.appendingPathComponent("system.wav"),
            to: tempDir.appendingPathComponent("system.wav"))

        // meta.json: длительность 600 с, чтобы пройти порог >300
        let now = Date()
        let meetingId = tempDir.lastPathComponent
        let meta = MeetingMeta(
            id: meetingId,
            source: "kontur.talk",
            startedAt: now.addingTimeInterval(-600),
            endedAt: now,
            durationSeconds: 600,
            status: .recording,
            asrModel: nil,
            title: "Встреча 09:44",
            schemaVersion: currentMetaSchemaVersion)
        try meta.write(to: tempDir.appendingPathComponent("meta.json"))

        // Прогон пайплайна с реальным LocalASR + реальным sidecar
        // AppPaths.sidecarBinary читает GOLOS_MEET_ASR_BIN автоматически
        let gigaamURL = URL(fileURLWithPath: gigaamDir)
        let pipeline = ProcessingPipeline(asrFactory: {
            LocalASR(engine: .gigaam, modelPath: gigaamURL)
        })
        await pipeline.process(folder: tempDir)

        // ── Assertions ──────────────────────────────────────────────────────────

        // 1. transcript.json существует и декодируется в Transcript с ≥1 сегментом
        let transcriptURL = tempDir.appendingPathComponent("transcript.json")
        #expect(FileManager.default.fileExists(atPath: transcriptURL.path),
                "transcript.json должен существовать после успешного прогона пайплайна")

        let transcriptData = try Data(contentsOf: transcriptURL)
        let dec = JSONDecoder()
        let transcript = try dec.decode(Transcript.self, from: transcriptData)
        #expect(transcript.segments.count >= 1,
                "транскрипт должен содержать хотя бы 1 сегмент; получено: \(transcript.segments.count)")

        // 2. transcript.md существует и не пустой
        let mdURL = tempDir.appendingPathComponent("transcript.md")
        #expect(FileManager.default.fileExists(atPath: mdURL.path),
                "transcript.md должен существовать")
        let mdContent = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(!mdContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "transcript.md не должен быть пустым")

        // 3. meta.json обновлён: status == .ready, asrModel == "gigaam-v3"
        let metaURL = tempDir.appendingPathComponent("meta.json")
        let reloaded = try MeetingMeta.decoded(Data(contentsOf: metaURL))
        #expect(reloaded.status == .ready,
                "статус встречи должен быть .ready; получено: \(String(describing: reloaded.status))")
        #expect(reloaded.asrModel == "gigaam-v3",
                "asrModel должен быть 'gigaam-v3'; получено: \(reloaded.asrModel ?? "nil")")
        #expect(reloaded.title == "Встреча 09:44",
                "title должен сохраняться через пайплайн; получено: \(reloaded.title ?? "nil")")
        #expect(reloaded.schemaVersion == currentMetaSchemaVersion,
                "schemaVersion должен сохраняться; получено: \(String(describing: reloaded.schemaVersion))")

        // 4. Хотя бы один сегмент содержит непустой текст
        let nonEmpty = transcript.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        #expect(!nonEmpty.isEmpty,
                "хотя бы один сегмент должен содержать непустой текст")

        // Логируем несколько сегментов для наглядности в отчёте
        print("[PipelineE2ETests] Всего сегментов: \(transcript.segments.count)")
        for seg in transcript.segments.prefix(5) {
            let tc = String(format: "%02d:%02d", Int(seg.start) / 60, Int(seg.start) % 60)
            print("[PipelineE2ETests] [\(tc)] \(seg.speaker.rawValue): \(seg.text)")
        }
    }
}
