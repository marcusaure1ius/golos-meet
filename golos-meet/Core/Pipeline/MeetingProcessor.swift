import Foundation
import Combine
import os

/// Отслеживает встречи «в обработке» и запускает ASR-пайплайн текущей моделью.
/// `MeetingLibrary` (read-model) этим не занимается — обработка живёт здесь.
@MainActor
final class MeetingProcessor: ObservableObject {
    /// id встреч, для которых сейчас идёт ASR-обработка (драйвит спиннер в UI).
    @Published private(set) var processing: Set<String> = []

    /// id встреч, для которых сейчас идёт генерация инсайтов (отдельно от ASR).
    @Published private(set) var insightsProcessing: Set<String> = []

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
            modelId: ASRSettings.current.modelId,
            insightsGenerator: makeInsightsGenerator())
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
        guard !insightsProcessing.contains(id) else { return }
        let gen = generator ?? MeetingProcessor.makeInsightsGenerator()
        guard let gen else { return }

        let trURL = folder.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: trURL),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data),
              !transcript.segments.isEmpty else { return }

        insightsProcessing.insert(id)
        defer { insightsProcessing.remove(id) }

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
    static func makeInsightsGenerator() -> InsightsGenerator? {
        let settings = UISettings.shared
        guard settings.llmEnabled else { return nil }
        let key = Keychain.get(account: Keychain.openRouterAccount) ?? ""
        guard !key.isEmpty else { return nil }
        let client = OpenRouterClient(apiKey: key)
        return InsightsGenerator(client: client, model: settings.llmModel)
    }
}
