import Foundation

/// One logical/physical operation in this production-owned worker. Timeout
/// fences durable state immediately, then drains a noncooperative adapter before
/// starting another operation; no growing pile of abandoned transport tasks.
@MainActor final class ProjectMemoryQueueWorker {
    #if DEBUG
    nonisolated let diagnosticOwnerID = UUID()
    private nonisolated let diagnosticObserver = MemoryQueueDiagnostics.observer
    func diagnosticSnapshot() -> [String: String] {
        var value = ["workerID": diagnosticOwnerID.uuidString, "started": String(started), "runID": run,
            "model": model, "revision": String(state.revision), "draining": String(worker != nil),
            "loadingPreview": String(loadingPreview), "refreshPending": String(refreshPending)]
        if let lease = active?.lease { value.merge(diagnosticLease(lease)) { _, new in new } }
        return value
    }
    private func diagnosticLease(_ lease: MemoryQueueLease) -> [String: String] {
        ["runID": lease.runID, "attemptID": lease.attempt, "jobGeneration": lease.job.generation,
         "cycleID": lease.job.cycle, "sequence": String(lease.job.sequence),
         "cursor": String(lease.job.completedChunks), "count": String(lease.count)]
    }
    private func diagnostic(_ stage: String, lease: MemoryQueueLease? = nil) {
        guard diagnosticObserver != nil else { return }
        var fields = diagnosticSnapshot()
        if let lease { fields.merge(diagnosticLease(lease)) { _, new in new } }
        MemoryQueueDiagnostics.record(diagnosticObserver, owner: diagnosticOwnerID, kind: "worker", stage: stage, fields: fields)
    }
    #endif
    private let store: ProjectStore
    private let history: ProjectMemoryHistoryService
    private let reader: KnowledgeSearchSourceReader
    private let meetings: URL
    private let documents: URL
    private let client: ChatCompleter
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var model: String
    private var started = false
    private var run = ""
    private var worker: Task<Void,Never>?
    private var active: (lease: MemoryQueueLease, service: ProjectMemoryUpdateService, task: Task<Void,Error>)?
    private var preview: (lease: MemoryQueueLease, service: ProjectMemoryUpdateService, request: MemoryUpdateRequest)?
    private var loadingPreview = false
    private var refreshPending = false
    private var cursor: Int64?
    private var state = MemoryQueueSnapshot()
    private var listeners: [UUID: AsyncStream<MemoryQueueSnapshot>.Continuation] = [:]
    init(store: ProjectStore, meetingsRoot: URL, documentsRoot: URL, client: ChatCompleter, model: String,
         timeout: Duration = .seconds(30), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store; meetings = meetingsRoot; documents = documentsRoot; self.client = client; self.model = model
        self.timeout = timeout; self.sleep = sleep
        reader = .init(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
        history = .init(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
    }
    func updates() -> AsyncStream<MemoryQueueSnapshot> {
        let id = UUID(), pair = AsyncStream<MemoryQueueSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[id] = pair.continuation; pair.continuation.yield(state)
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners.removeValue(forKey: id) } }
        return pair.stream
    }
    func snapshot() -> MemoryQueueSnapshot { state }
    func start() async {
        #if DEBUG
        diagnostic("start.request")
        defer { diagnostic("start.return") }
        #endif
        guard !started else { return }; started = true
        do {
            run = try await store.startMemoryQueueRun()
            #if DEBUG
            diagnostic("run.started")
            #endif
            await changed()
        }
        catch { state.message = "Не удалось восстановить очередь памяти."; await emit() }
    }
    func changed(model: String? = nil) async {
        #if DEBUG
        diagnostic("changed.begin")
        defer { diagnostic("changed.return") }
        #endif
        if let model { self.model = model }
        refreshPending = true
        do {
            try await reconcile()
            if let active {
                do { try await store.validateMemoryQueue(active.lease) } catch { active.service.cancel(); active.task.cancel() }
            }
            if let preview {
                do { try await store.validateMemoryQueue(preview.lease) }
                catch { preview.service.cancel(); self.preview = nil }
            }
            state.message = nil
        } catch {
            state.message = "Источники меняются или библиотека недоступна. Очередь ждёт следующего события."
            if !run.isEmpty, (try? await store.memoryQueueRunCurrent(run)) == false { await stop() }
        }
        await emit(); if started { launch() }
    }
    func stop() async {
        #if DEBUG
        diagnostic("stop.begin")
        defer { diagnostic("stop.return") }
        #endif
        started = false; refreshPending = false
        let stoppingWorker = worker
        let stoppingPreview = preview
        if let active {
            try? await store.setMemoryQueueState(active.lease, state: active.lease.job.completedChunks > 0 ? .partial : .queued, message: "Остановлено; продолжим после запуска.")
            active.service.cancel(); active.task.cancel()
        }
        if let preview = stoppingPreview {
            try? await store.setMemoryQueueState(preview.lease, state: .needsConsent, message: "Нужно новое разовое разрешение после запуска.")
            preview.service.cancel()
            if self.preview?.request.id == preview.request.id { self.preview = nil }
        }
        stoppingWorker?.cancel(); await emit()
    }
    func cancel(_ sequence: Int64) async {
        do { try await store.cancelMemoryQueue(sequence, run: run.isEmpty ? nil : run) } catch { state.message = "Не удалось сохранить отмену." }
        if active?.lease.job.sequence == sequence { active?.service.cancel(); active?.task.cancel() }
        if preview?.lease.job.sequence == sequence { preview?.service.cancel(); preview = nil }
        await emit()
    }
    func retry(_ sequence: Int64) async {
        do { try await store.retryMemoryQueue(sequence, run: run.isEmpty ? nil : run); await changed() }
        catch { state.message = "Не удалось повторить обработку."; await emit() }
    }
    /// The panel requests a fresh exact batch preview explicitly. Only one
    /// consent preview is kept, never persisted or recreated as approval.
    func preparePreview(_ sequence: Int64) async throws -> MemoryUpdateRequest {
        guard started, active == nil, worker == nil, !loadingPreview else { throw MemoryQueueError.busy }
        loadingPreview = true; let previewRun = run
        defer { loadingPreview = false; if started { launch() } }
        if let old = preview {
            old.service.cancel(); try await store.setMemoryQueueState(old.lease, state: .needsConsent, message: "Предпросмотр заменён."); preview = nil
        }
        try await reconcile()
        guard started, run == previewRun else { throw MemoryQueueError.stale }
        guard let lease = try await store.claimMemoryQueue(run: run, after: cursor, explicit: sequence) else { throw MemoryQueueError.notReady }
        let service = makeService()
        do {
            let request = try await prepare(lease, service: service)
            guard started, run == previewRun else { throw MemoryQueueError.stale }
            if request.denied {
                try await store.setMemoryQueueState(lease, state: .denied, message: "Один из владельцев запрещает облако.")
                service.cancel()
            } else {
                try await store.pauseMemoryQueueForConsent(lease)
                preview = (lease,service,request)
            }
            await emit(); return request
        } catch {
            try? await store.setMemoryQueueState(lease, state: failureState(error), message: safeMessage(error))
            service.cancel(); await emit(); throw error
        }
    }
    func approvePreview(_ requestID: UUID) async throws {
        guard started, active == nil, worker == nil, !loadingPreview else { throw MemoryQueueError.busy }
        let approvingRun = run
        guard let pending = preview, pending.request.id == requestID else { throw MemoryUpdateError.invalidConsent }
        loadingPreview = true; defer { loadingPreview = false; if started { launch() } }
        // Keep this project paused while issuing exact consent and starting the
        // serial operation. The token is never written to SQLite.
        let token = try await pending.service.approve(pending.request)
        guard started, run == approvingRun, preview?.request.id == requestID, active == nil else { throw MemoryUpdateError.invalidConsent }
        try await store.resumeMemoryQueueConsent(pending.lease)
        preview = nil
        await process(pending.lease, service: pending.service, prepared: pending.request, consent: token)
        // Explicitly approved batches can retire another job's consumed memory
        // just like background batches. Reconcile before claiming more work.
        refreshPending = true
        if started { launch() }
    }
    func discardPreview() async {
        if let preview {
            preview.service.cancel(); try? await store.setMemoryQueueState(preview.lease, state: .needsConsent, message: "Нужно новое разовое разрешение."); self.preview = nil
        }
        await emit(); if started { launch() }
    }
    func waitUntilIdle() async { while let task = worker { await task.value } }
    private func makeService() -> ProjectMemoryUpdateService {
        .init(store: store, meetingsRoot: meetings, documentsRoot: documents, client: client, model: model)
    }
    private func reconcile() async throws {
        #if DEBUG
        diagnostic("discovery.begin")
        #endif
        let catalog = try await store.knowledgeSearchCatalog(scope: .all)
        var identities: [EmbeddingSourceKey: String] = [:]
        for source in catalog.sources {
            try Task.checkCancellation()
            identities[source.key] = try? await reader.identity(source)
        }
        try await store.reconcileMemoryQueue(catalog: catalog, identities: identities, generatorModel: model, contract: MemoryFactExtractor.producerKey(model: model, payload: "", hits: [], parents: []), run: run.isEmpty ? nil : run)
        refreshPending = false
        #if DEBUG
        diagnostic("discovery.return")
        #endif
    }
    private func launch() {
        guard started, worker == nil, active == nil, !loadingPreview else { return }
        worker = Task(priority: .utility) { await self.drain() }
    }
    private func drain() async {
        let ownedRun = run
        do {
            var budget = 256
            while started, !Task.isCancelled, !loadingPreview, budget > 0 {
                budget -= 1
                if refreshPending { try await reconcile() }
                guard let lease = try await store.claimMemoryQueue(run: run, after: cursor, excluding: preview?.lease.job.projectID) else {
                    // claim may have marked an oversized first chunk limited;
                    // do not let that source starve ordinary work behind it.
                    if try await store.hasMemoryQueueWork(excluding: preview?.lease.job.projectID) { continue }
                    break
                }
                #if DEBUG
                diagnostic("lease.claimed", lease: lease)
                #endif
                cursor = lease.job.sequence
                await process(lease, service: makeService())
                // Fill backpressure slots after a completed batch without
                // scheduling processed sources just because heads changed.
                refreshPending = true
            }
            if budget == 0 { refreshPending = true }
        } catch is CancellationError {} catch {
            state.message = "Очередь остановилась на изменённых или недоступных данных. Повторите проверку."
        }
        worker = nil; await emit()
        if started, (refreshPending || run != ownedRun), state.message == nil { launch() }
    }
    private func prepare(_ lease: MemoryQueueLease, service: ProjectMemoryUpdateService) async throws -> MemoryUpdateRequest {
        let catalog = try await store.knowledgeSearchCatalog(scope: .project(lease.job.projectID))
        guard var source = catalog.sources.first(where: { $0.key == lease.job.source }),
              try await reader.identity(source) == lease.fileStamp else { throw MemoryQueueError.stale }
        source.title = await reader.title(source)
        let chunks = try await store.memoryQueueChunks(lease)
        guard chunks.count == lease.count else { throw MemoryQueueError.stale }
        var hits = chunks.map { KnowledgeSearchHit(source: source, chunk: $0, model: catalog.model, scope: .project(lease.job.projectID), matchedWords: false, matchedMeaning: true, fileStamp: lease.fileStamp) }
        let heads = try await history.heads(projectID: lease.job.projectID, limit: 8)
        // Do not consume this source's own previous batch as derived input.
        // Old overview context is a bounded selection, never the whole archive.
        var parents: [MemoryEvent] = [], parentCharacters = 0
        for head in heads.heads where head.usableAsCurrent && !head.entry.event.sources.contains(where: { $0.key == source.key }) {
            let value = head.entry.event
            let size = value.statement.text.count + value.statement.subject.count + value.statement.conditions.reduce(0) { $0 + $1.key.count + $1.value.count } + 100
            if parentCharacters + size <= 4000 { parents.append(value); parentCharacters += size }
        }
        parents.sort { $0.id.uuidString < $1.id.uuidString }
        guard let project = try await store.snapshot().projects.first(where: { $0.id == lease.job.projectID }) else { throw MemoryQueueError.stale }
        // Account for repeated titles and JSON escaping as well as raw text.
        // Shrinking the prefix changes the durable count, never skips chunks.
        while !hits.isEmpty {
            let characters = hits.reduce(0) { $0 + $1.chunk.text.count + $1.source.title.count }
            if characters <= 16_000, (try? MemoryFactExtractor.payload(project: project, hits: hits, parents: parents)) != nil { break }
            hits.removeLast()
        }
        guard !hits.isEmpty else { throw MemoryQueueError.budget }
        let batch = MemoryQueueLease(runID: lease.runID, attempt: lease.attempt, job: lease.job, count: hits.count, fileStamp: lease.fileStamp)
        return try await service.prepare(projectID: lease.job.projectID, hits: hits, parentEventIDs: parents.map(\.id), queue: batch)
    }
    private func process(_ lease: MemoryQueueLease, service: ProjectMemoryUpdateService, prepared: MemoryUpdateRequest? = nil, consent: MemoryUpdateConsent? = nil) async {
        guard started, run == lease.runID else {
            try? await store.setMemoryQueueState(lease, state: .queued, message: "Операция остановлена до отправки."); service.cancel(); return
        }
        let task = Task {
            guard self.started, self.run == lease.runID else { throw CancellationError() }
            let request: MemoryUpdateRequest
            if let prepared { request = prepared } else { request = try await self.prepare(lease, service: service) }
            if request.denied {
                try await self.store.setMemoryQueueState(lease, state: .denied, message: "Один из владельцев запрещает облако."); service.cancel(); return
            }
            if !request.approvalProjectIDs.isEmpty, consent == nil {
                try await self.store.pauseMemoryQueueForConsent(lease); service.cancel(); return
            }
            #if DEBUG
            self.diagnostic("update.begin", lease: lease)
            #endif
            #if DEBUG
            let outcome = try await service.update(request, consent: consent)
            switch outcome {
            case .published(let publication):
                switch publication {
                case .inserted: self.diagnostic("publication.inserted.return", lease: lease)
                case .unchanged: self.diagnostic("publication.unchanged.return", lease: lease)
                }
            case .insufficientEvidence: self.diagnostic("insufficient.return", lease: lease)
            }
            #else
            _ = try await service.update(request, consent: consent)
            #endif
        }
        active = (lease,service,task)
        #if DEBUG
        diagnostic("attempt.active", lease: lease)
        #endif
        let timer = Task {
            do {
                try await sleep(timeout)
                guard active?.lease.attempt == lease.attempt else { return }
                try await store.setMemoryQueueState(lease, state: .failed, message: "Обработка превысила 30 секунд. Можно повторить после завершения отмены.")
                service.cancel(); task.cancel(); await emit()
            } catch {}
        }
        await emit()
        do {
            try await task.value
            #if DEBUG
            diagnostic("attempt.return", lease: lease)
            #endif
        }
        catch {
            #if DEBUG
            diagnostic("attempt.error", lease: lease)
            #endif
            try? await store.setMemoryQueueState(lease, state: failureState(error), message: safeMessage(error))
        }
        timer.cancel()
        if active?.lease.attempt == lease.attempt { active = nil }
        await emit()
    }
    private func failureState(_ error: Error) -> MemoryQueueState {
        if error is CancellationError { return .cancelled }
        if error as? KnowledgeAnswerError == .cloudNotAllowed { return .denied }
        if error as? MemoryUpdateError == .candidateLimit || error as? MemoryUpdateError == .contextTooLarge || error as? MemoryQueueError == .budget || error as? ProjectMemoryError == .limited { return .limited }
        if error as? MemoryUpdateError == .notReady || error as? MemoryQueueError == .notReady { return .waiting }
        if error as? MemoryUpdateError == .consentRequired { return .needsConsent }
        if error is KnowledgeSearchError || error as? ProjectMemoryError == .stale || error as? ProjectMemoryError == .unavailable || error as? ProjectMemoryError == .missing || error as? MemoryUpdateError == .stale || error as? MemoryQueueError == .stale { return .stale }
        return .failed
    }
    private func safeMessage(_ error: Error) -> String {
        if let error = error as? MemoryUpdateError { return error.localizedDescription }
        if let error = error as? MemoryQueueError { return error.localizedDescription }
        if error is CancellationError { return "Обработка отменена." }
        if error as? LLMError == .noAPIKey { return "Задайте ключ OpenRouter в настройках и повторите batch." }
        return "Не удалось обработать batch. Память не заменена; можно повторить после проверки источника и разрешений."
    }
    private func emit() async {
        state.revision += 1; let revision = state.revision, message = state.message
        do {
            var latest = try await store.memoryQueueSnapshot()
            guard revision == state.revision else { return }
            latest.revision = revision; latest.message = message; state = latest
        } catch { state.message = "Не удалось прочитать очередь памяти." }
        for listener in listeners.values { listener.yield(state) }
    }
}
