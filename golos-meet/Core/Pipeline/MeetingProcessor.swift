import Foundation
import Combine
import os

/// Задача единой очереди обработки.
struct ProcessingJob: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Полный пайплайн: порог → ASR обеих дорожек → merge → инсайты → статус.
        case process(deleteShortAudio: Bool)
        /// Только инсайты по готовому transcript.json (без sidecar).
        case insights
    }

    let meetingId: String
    let folder: URL
    let kind: Kind

    var isProcess: Bool { if case .process = kind { return true }; return false }
    /// Конфиг process в id не входит: повтор с другим конфигом — дубликат.
    var id: String { "\(meetingId)|\(isProcess ? "process" : "insights")" }
}

/// Одна задача «догнать»: встреча + что для неё доделать. Результат чистого решения
/// `MeetingProcessor.catchUpJobs`, который потом ставится в очередь через `enqueueCatchUp`.
struct CatchUpJob: Equatable {
    let id: String
    let kind: ProcessingJob.Kind
}

/// Единая последовательная очередь всей обработки (FIFO, строго по одной задаче).
/// Источники: конец записи (Recorder), «Переобработать»/«Сгенерировать» из UI,
/// Backfill, спасённые встречи при старте (StartupRescue).
@MainActor
final class MeetingProcessor: ObservableObject {
    /// Единый экземпляр для app-wiring (Recorder/AppDelegate/UI). Тесты создают свои.
    static let shared = MeetingProcessor()

    @Published private(set) var queuedJobs: [ProcessingJob] = []
    @Published private(set) var activeJob: ProcessingJob?
    /// Счётчик завершённых задач; растёт после каждой — сигнал UI перечитать ленту.
    @Published private(set) var completedJobsCount = 0

    /// id встреч с задачей `.process` (в очереди или активной) — драйвит спиннеры ASR.
    var processing: Set<String> {
        var ids = Set(queuedJobs.filter(\.isProcess).map(\.meetingId))
        if let a = activeJob, a.isProcess { ids.insert(a.meetingId) }
        return ids
    }

    /// id встреч с задачей `.insights` (в очереди или активной).
    var insightsProcessing: Set<String> {
        var ids = Set(queuedJobs.filter { $0.kind == .insights }.map(\.meetingId))
        if let a = activeJob, a.kind == .insights { ids.insert(a.meetingId) }
        return ids
    }

    /// Встреча ждёт в очереди (не активна) — бейдж «В очереди».
    func isQueued(_ meetingId: String) -> Bool {
        queuedJobs.contains { $0.meetingId == meetingId }
    }

    /// Уникальные встречи в работе (активная + очередь) — счётчик баннера.
    var busyMeetingsCount: Int {
        var ids = Set(queuedJobs.map(\.meetingId))
        if let a = activeJob { ids.insert(a.meetingId) }
        return ids.count
    }

    // Рабочие функции; инъектируются в тестах, по умолчанию — реальные пайплайн и LLM.
    private let processWork: @MainActor (URL, PipelineConfig) async -> Void
    private let insightsWork: @MainActor (String, URL) async -> Void

    private var worker: Task<Void, Never>?
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(processWork: (@MainActor (URL, PipelineConfig) async -> Void)? = nil,
         insightsWork: (@MainActor (String, URL) async -> Void)? = nil) {
        self.processWork = processWork ?? { folder, config in
            let pipeline = ProcessingPipeline(
                asrFactory: { LocalASR.forChoice(ASRSettings.current) },
                config: config,
                modelId: ASRSettings.current.modelId,
                insightsGenerator: MeetingProcessor.makeInsightsGenerator())
            await pipeline.process(folder: folder)
        }
        self.insightsWork = insightsWork ?? { id, folder in
            await MeetingProcessor.runInsights(
                id: id, folder: folder,
                generator: MeetingProcessor.makeInsightsGenerator())
        }
    }

    // MARK: Очередь

    /// Ставит задачу (fire-and-forget). Дедупликация по встрече:
    /// 1) `.process` вытесняет ЖДУЩУЮ `.insights` той же встречи (полная обработка её включает);
    /// 2) `.insights` игнорируется, если у встречи уже есть `.process` (в очереди или активная);
    /// 3) повтор того же типа — игнор.
    func enqueue(_ kind: ProcessingJob.Kind, id: String, folder: URL) {
        let job = ProcessingJob(meetingId: id, folder: folder, kind: kind)
        guard !isPending(job.id) else { return }                          // правило 3
        if case .insights = kind, pendingProcessJob(for: id) != nil { return }  // правило 2
        if job.isProcess,
           let idx = queuedJobs.firstIndex(where: { $0.meetingId == id && $0.kind == .insights }) {
            // Правило 1: ожидающие вытесненной insights-задачи переезжают на process.
            let removed = queuedJobs.remove(at: idx)
            if let moved = waiters.removeValue(forKey: removed.id) {
                waiters[job.id, default: []].append(contentsOf: moved)
            }
        }
        queuedJobs.append(job)
        pump()
    }

    /// enqueue + ожидание завершения (для UI: перезагрузить транскрипт/заголовок после).
    /// Если insights срезана правилом 2 — ждём process-задачу той же встречи.
    func enqueueAndWait(_ kind: ProcessingJob.Kind, id: String, folder: URL) async {
        enqueue(kind, id: id, folder: folder)
        let jobId = ProcessingJob(meetingId: id, folder: folder, kind: kind).id
        let waitId: String
        if isPending(jobId) {
            waitId = jobId
        } else if case .insights = kind, let p = pendingProcessJob(for: id) {
            waitId = p.id
        } else {
            return   // ничего не поставилось и ждать нечего
        }
        await withCheckedContinuation { waiters[waitId, default: []].append($0) }
    }

    // MARK: «Догнать» недоделанные встречи (кнопка «Обновить»)

    /// Чистое решение: какие встречи не доведены до конца и что для них поставить.
    /// Нет транскрипта, но есть аудио → полный пайплайн; есть транскрипт, но нет инсайтов
    /// → только инсайты (когда LLM настроен). Пишущиеся/отброшенные пропускаем;
    /// дедуп уже активных/стоящих в очереди — за `enqueue`.
    static func catchUpJobs(for summaries: [MeetingSummary], insightsEnabled: Bool) -> [CatchUpJob] {
        summaries.compactMap { m in
            if m.status == .recording || m.status == .discarded { return nil }
            if !m.hasTranscript && m.hasAudio {
                return CatchUpJob(id: m.id, kind: .process(deleteShortAudio: true))
            }
            if insightsEnabled && m.hasTranscript && !m.hasInsights {
                return CatchUpJob(id: m.id, kind: .insights)
            }
            return nil
        }
    }

    /// Ставит в очередь всё недоделанное из `summaries`. Возвращает число поставленных задач.
    @discardableResult
    func enqueueCatchUp(summaries: [MeetingSummary], insightsEnabled: Bool) -> Int {
        let jobs = MeetingProcessor.catchUpJobs(for: summaries, insightsEnabled: insightsEnabled)
        for j in jobs { enqueue(j.kind, id: j.id, folder: AppPaths.meetingDir(j.id)) }
        return jobs.count
    }

    private func isPending(_ jobId: String) -> Bool {
        activeJob?.id == jobId || queuedJobs.contains { $0.id == jobId }
    }

    private func pendingProcessJob(for meetingId: String) -> ProcessingJob? {
        if let a = activeJob, a.meetingId == meetingId, a.isProcess { return a }
        return queuedJobs.first { $0.meetingId == meetingId && $0.isProcess }
    }

    /// Запускает воркер, если он не крутится. Воркер выгребает очередь по одной задаче.
    private func pump() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            while let self, !self.queuedJobs.isEmpty {
                let job = self.queuedJobs.removeFirst()
                self.activeJob = job
                await self.run(job)
                self.activeJob = nil
                self.completedJobsCount += 1
                (self.waiters.removeValue(forKey: job.id) ?? []).forEach { $0.resume() }
            }
            self?.worker = nil
        }
    }

    private func run(_ job: ProcessingJob) async {
        switch job.kind {
        case .process(let deleteShort):
            await processWork(job.folder, PipelineConfig(deleteShortAudio: deleteShort))
        case .insights:
            await insightsWork(job.meetingId, job.folder)
        }
    }

    // MARK: Инсайты по готовому транскрипту

    /// Инсайты без ASR: transcript.json → insights.json + meta.title.
    /// Ошибка LLM не роняет встречу — статус возвращается в ready.
    static func runInsights(id: String, folder: URL, generator: InsightsGenerator?) async {
        guard let gen = generator else { return }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data),
              !transcript.segments.isEmpty else { return }

        let metaURL = folder.appendingPathComponent("meta.json")
        guard var meta = try? MeetingMeta.decoded(Data(contentsOf: metaURL)) else {
            Log.llm.error("\(id, privacy: .public): insights aborted — meta.json не прочитан")
            return
        }
        meta.status = .summarizing
        try? meta.write(to: metaURL)
        do {
            let insights = try await gen.generate(from: transcript, meetingId: id)
            try insights.write(to: folder.appendingPathComponent("insights.json"))
            if meta.titleManual != true { meta.title = insights.title }
            Log.llm.info("\(id, privacy: .public): insights ok (\(insights.actionPoints.count) action points)")
        } catch {
            Log.llm.error("\(id, privacy: .public): insights failed — \(error.localizedDescription, privacy: .public)")
        }
        meta.status = .ready
        // Пользователь мог переименовать встречу вручную, пока шла обработка — не затирать свежий ручной заголовок.
        if let fresh = try? MeetingMeta.decoded(Data(contentsOf: metaURL)), fresh.titleManual == true {
            meta.title = fresh.title
            meta.titleManual = true
        }
        try? meta.write(to: metaURL)
    }

    /// Собирает генератор инсайтов из настроек/Keychain. nil → LLM-шаг выключен.
    static func makeInsightsGenerator() -> InsightsGenerator? {
        let settings = UISettings.shared
        guard settings.llmEnabled else { return nil }
        let key = Keychain.get(account: Keychain.openRouterAccount) ?? ""
        guard !key.isEmpty else { return nil }
        let client = OpenRouterClient(apiKey: key)
        return InsightsGenerator(client: client, model: settings.generationModel.rawValue)
    }
}
