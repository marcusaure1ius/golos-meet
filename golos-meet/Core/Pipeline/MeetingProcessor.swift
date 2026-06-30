import Foundation
import Combine
import os

/// Отслеживает встречи «в обработке» и запускает ASR-пайплайн текущей моделью.
/// `MeetingLibrary` (read-model) этим не занимается — обработка живёт здесь.
@MainActor
final class MeetingProcessor: ObservableObject {
    /// id встреч, для которых сейчас идёт обработка (драйвит спиннер в UI).
    @Published private(set) var processing: Set<String> = []

    /// Рабочая функция: что делать с папкой встречи. Инъектируется для тестов;
    /// по умолчанию — реальный `ProcessingPipeline`.
    private let work: @MainActor (URL) async -> Void

    init(work: (@MainActor (URL) async -> Void)? = nil) {
        self.work = work ?? MeetingProcessor.runPipeline
    }

    /// Реальный прогон: текущая модель (`ASRSettings.current`), без удаления коротких записей.
    static func runPipeline(_ folder: URL) async {
        let pipeline = ProcessingPipeline(
            asrFactory: { LocalASR.forChoice(ASRSettings.current) },
            config: PipelineConfig(deleteShortAudio: false),
            modelId: ASRSettings.current.modelId)
        await pipeline.process(folder: folder)
    }

    /// Переобработать (или впервые расшифровать) встречу. Повторный вызов для той же
    /// встречи, пока она в обработке, игнорируется.
    func reprocess(id: String, folder: URL) async {
        guard !processing.contains(id) else { return }
        processing.insert(id)
        await work(folder)
        processing.remove(id)
    }

    /// Ручная (пере)генерация инсайтов по уже готовому transcript.json — без ASR/sidecar.
    /// `generator` по умолчанию nil; при nil пробует фабрику `makeInsightsGenerator()`.
    func regenerateInsights(id: String, folder: URL, generator: InsightsGenerator? = nil) async {
        guard !processing.contains(id) else { return }
        let gen = generator ?? MeetingProcessor.makeInsightsGenerator()
        guard let gen else { return }

        let trURL = folder.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: trURL),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data),
              !transcript.segments.isEmpty else { return }

        processing.insert(id)
        defer { processing.remove(id) }

        let metaURL = folder.appendingPathComponent("meta.json")
        var meta = try? MeetingMeta.decoded(Data(contentsOf: metaURL))
        meta?.status = .summarizing
        if let meta { try? meta.write(to: metaURL) }

        do {
            let insights = try await gen.generate(from: transcript, meetingId: id)
            try insights.write(to: folder.appendingPathComponent("insights.json"))
            meta?.title = insights.title
        } catch {
            Log.llm.error("\(id, privacy: .public): manual insights failed — \(error.localizedDescription, privacy: .public)")
        }

        meta?.status = .ready
        if let meta { try? meta.write(to: metaURL) }
    }

    /// Собирает генератор инсайтов из настроек/Keychain. nil → LLM-шаг выключен.
    /// Тело дополняется в задаче настроек (Task 11).
    static func makeInsightsGenerator() -> InsightsGenerator? {
        nil
    }
}
