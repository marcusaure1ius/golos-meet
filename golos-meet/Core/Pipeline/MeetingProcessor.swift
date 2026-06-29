import Foundation
import Combine

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
}
