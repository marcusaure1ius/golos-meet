import Foundation

/// One serial utility worker owns both model activation and index publication.
/// Producers only request reconciliation; they never wait for model inference.
actor LocalIndexingService {
    typealias Inspector = @Sendable () async throws -> LocalEmbeddingCandidate?
    private let store: ProjectStore
    private let root: URL
    private let reader: MeetingEmbeddingSnapshotReader
    private let inspect: Inspector
    private var started = false
    private var recovered = false
    private var reconcilePending = false
    private var reloadPending = false
    private var modelRequest = UUID()
    private var runtimeGeneration = UUID()
    private var runtime: (encoder: any LocalPassageEmbedding, model: EmbeddingIndexModel, folder: URL?)?
    private var worker: Task<Void, Never>?
    private var active: (lease: EmbeddingIndexLease, task: Task<Void, Error>)?
    private var cursor: String?
    private var state = LocalIndexingSnapshot()
    private var listeners: [UUID: AsyncStream<LocalIndexingSnapshot>.Continuation] = [:]
    private var lastEmit = 0.0

    init(store: ProjectStore, meetingsRoot: URL, inspect: @escaping Inspector) {
        self.store = store; root = meetingsRoot; reader = MeetingEmbeddingSnapshotReader(root: meetingsRoot)
        self.inspect = inspect
    }

    func updates() -> AsyncStream<LocalIndexingSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LocalIndexingSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return stream
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }

    func start() {
        guard !started else { return }
        started = true; reconcilePending = true; reloadPending = true
        launch()
    }
    func changed(source: EmbeddingSourceKey? = nil) {
        reconcilePending = true
        if let active, source == active.lease.job.source {
            active.task.cancel()
        }
        if started { launch() }
    }
    func modelChanged() {
        modelRequest = UUID(); reloadPending = true
        active?.task.cancel()
        if started { launch() }
    }
    func filesChanged(_ paths: [String], modelsRoot: URL) {
        let meetings = Self.eventPath(root)
        let models = Self.eventPath(modelsRoot)
        let activeFolder = runtime?.folder.map(Self.eventPath)
        var sourceChanges: Set<EmbeddingSourceKey> = []
        var reconcile = false, reload = false
        for raw in paths {
            let path = Self.eventPath(URL(fileURLWithPath: raw))
            if path == meetings { reconcile = true }
            else if path.hasPrefix(meetings + "/") {
                let relative = String(path.dropFirst(meetings.count + 1)).split(separator: "/")
                if relative.count == 1 || relative.last == "transcript.json" || relative.last == "meta.json" {
                    reconcile = true
                    if let id = relative.first { sourceChanges.insert(.init(kind: .meeting, externalID: String(id))) }
                }
            }
            if path == models || path == models + "/active.json" { reload = true }
            if let activeFolder, path == activeFolder || path.hasPrefix(activeFolder + "/") { reload = true }
        }
        if reconcile {
            reconcilePending = true
            if let active, sourceChanges.contains(active.lease.job.source) { active.task.cancel() }
            if started { launch() }
        }
        if reload { modelChanged() }
    }

    /// Foundation resolves /private/var to /var only while the whole path
    /// exists. Resolve the nearest existing parent, then append missing entries;
    /// otherwise delete events miss the watched prefix. Preserve the final entry
    /// so a transcript replaced by a symlink is invalidated, not followed away.
    nonisolated static func eventPath(_ url: URL) -> String {
        var parent = url.standardizedFileURL.deletingLastPathComponent()
        var suffix = [url.lastPathComponent]
        while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
            suffix.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
        var result = parent.resolvingSymlinksInPath()
        for component in suffix.reversed() { result.appendPathComponent(component) }
        return result.path
    }
    func cancel(_ key: EmbeddingSourceKey) async {
        if active?.lease.job.source == key { active?.task.cancel() }
        do { try await store.cancelEmbeddingJob(key) } catch { state.storageMessage = "Не удалось сохранить отмену. Повторите действие." }
        await emit()
    }
    func retry(_ key: EmbeddingSourceKey) async {
        do { try await store.retryEmbeddingJob(key); reconcilePending = true; if started { launch() } }
        catch { state.storageMessage = "Не удалось повторить индексирование." }
        await emit()
    }
    func retryAll() async {
        do {
            for job in try await store.embeddingJobs() where [.failed, .cancelled].contains(job.state) {
                try await store.retryEmbeddingJob(job.source)
            }
            reconcilePending = true; if started { launch() }
        } catch { state.storageMessage = "Не удалось повторить индексирование." }
        await emit()
    }
    func cancelAll() async {
        active?.task.cancel()
        do { try await store.cancelPendingEmbeddingJobs() }
        catch { state.storageMessage = "Не удалось сохранить отмену. Повторите действие." }
        await emit()
    }
    func stop() async {
        started = false
        modelRequest = UUID()
        active?.task.cancel(); worker?.cancel()
        await worker?.value
        if !started {
            runtime = nil; state.hasWorkingModel = false; state.modelState = .idle
            state.modelMessage = "Индексирование остановлено."
            await emit()
        }
    }
    func waitUntilIdle() async { while let current = worker { await current.value } }
    func snapshot() -> LocalIndexingSnapshot { state }

    /// Refresh catalog bytes before retrieval, without waiting for inference of
    /// the whole queue. CAS/leases fence an overlapping active index attempt.
    func synchronizeForSearch() async throws -> [EmbeddingSourceKey] {
        try await reconcile()
        if started { launch() }
        return Array(state.sourceErrors.keys)
    }

    /// Consumers cannot activate a model. A query which outlives any model
    /// request, including A→B→A, is explicitly superseded instead of restoring A.
    func embedQuery(_ text: String) async throws -> KnowledgeVector {
        guard let runtime, !reloadPending, state.modelState != .checking, state.hasWorkingModel else { throw LocalIndexingError.missingModel }
        let request = modelRequest
        let generation = runtimeGeneration
        let values = try await runtime.encoder.embed([text], purpose: .query)
        guard request == modelRequest, generation == runtimeGeneration, !reloadPending else { throw LocalIndexingError.superseded }
        guard let value = values.first, value.modelID == runtime.model.id else { throw EmbeddingIndexError.invalidVectors }
        return value
    }

    private func launch() {
        guard worker == nil else { return }
        worker = Task(priority: .utility) { await self.drain() }
    }
    private func drain() async {
        do {
            if !recovered {
                try await store.recoverEmbeddingJobs()
                recovered = true
            }
            while started, !Task.isCancelled {
                if reconcilePending {
                    reconcilePending = false
                    try await reconcile()
                }
                if reloadPending {
                    reloadPending = false
                    await reloadModel()
                    continue
                }
                guard let runtime else { break }
                guard let lease = try await store.claimEmbeddingJob(after: cursor) else { break }
                guard started, !Task.isCancelled else { try await store.interruptEmbeddingJob(lease); break }
                cursor = lease.job.source.rawValue // round robin, including superseded work
                if lease.model != runtime.model { try await store.interruptEmbeddingJob(lease); break }
                await process(lease, encoder: runtime.encoder)
            }
        } catch is CancellationError {
            // The active attempt is released by process(), not startup recovery.
        } catch { state.storageMessage = "Не удалось прочитать или сохранить индекс. Повторите проверку библиотеки." }
        worker = nil
        await emit()
        // An event arriving during the final async database read cannot be lost.
        if started, state.storageMessage == nil, (reconcilePending || reloadPending) { launch() }
    }

    private func reloadModel() async {
        let request = modelRequest
        state.modelState = .checking; state.modelMessage = "Проверяем локальную модель…"
        await emit()
        do {
            guard let candidate = try await inspect() else {
                guard request == modelRequest else { return }
                if runtime == nil { state.modelState = .missing; state.modelMessage = "Для индексирования скачайте модель или выберите папку в настройках." }
                else { state.modelState = .failed; state.modelMessage = "Файлы модели недоступны. Загруженная модель продолжает работать; проверьте установку." }
                return
            }
            guard request == modelRequest, !Task.isCancelled else { return }
            let encoder: any LocalPassageEmbedding
            if let existing = runtime, existing.model == candidate.model { encoder = existing.encoder }
            else { encoder = try await candidate.load() }
            guard request == modelRequest, !Task.isCancelled else { return }
            guard encoder.modelID == candidate.model.id, encoder.dimensions == candidate.model.dimensions else { throw EmbeddingIndexError.invalidModel }
            // Only this serial worker calls activate. A later request cannot be
            // activated until this await finishes and the latest load is chosen.
            try await store.activateEmbeddingModel(candidate.model)
            // Keep cache consistent with an activation which already committed,
            // even if a newer request arrived during that cross-actor await.
            runtime = (encoder, candidate.model, candidate.folder)
            runtimeGeneration = UUID()
            state.hasWorkingModel = true
            guard request == modelRequest, !Task.isCancelled else { return }
            state.modelState = .ready; state.modelMessage = "Модель проверена и работает локально."
        } catch {
            guard request == modelRequest else { return }
            state.modelState = .failed
            state.modelMessage = runtime == nil ? "Не удалось проверить модель. Повторите установку или выберите совместимую папку." : "Новая модель недоступна. Прежняя рабочая модель сохранена."
        }
        await emit()
    }

    private func process(_ lease: EmbeddingIndexLease, encoder: any LocalPassageEmbedding) async {
        let store = store, reader = reader
        let task = Task(priority: .utility) {
            var results: [IndexedChunkVectors] = []
            for (index, chunk) in lease.snapshot.chunks.enumerated() {
                try Task.checkCancellation()
                let windows = try await encoder.passageWindows(chunk.text)
                guard let last = windows.last else { throw EmbeddingIndexError.invalidVectors }
                results.append(.init(chunkID: chunk.id, bodyTokenCount: last.tokenStart + last.tokenCount, windows: windows))
                guard try await store.updateEmbeddingProgress(lease, completed: index + 1) else { throw CancellationError() }
                await self.progress()
            }
            try Task.checkCancellation()
            if lease.job.source.kind == .meeting {
                guard try await reader.synchronize(meetingID: lease.job.source.externalID, store: store) else { throw CancellationError() }
            }
            try Task.checkCancellation()
            _ = try await store.publishEmbeddingVectors(results, lease: lease)
        }
        active = (lease, task)
        await emit()
        do { try await task.value }
        catch is CancellationError { try? await store.interruptEmbeddingJob(lease) }
        catch {
            _ = try? await store.failEmbeddingJob(lease)
        }
        active = nil
        await emit()
    }

    private func progress() async {
        if ProcessInfo.processInfo.systemUptime - lastEmit > 0.2 { await emit() }
    }
    private func emit() async {
        lastEmit = ProcessInfo.processInfo.systemUptime
        state.revision += 1
        var snapshot = state
        do {
            let summary = try await store.embeddingQueueSummary()
            snapshot.jobs = summary.jobs; snapshot.counts = summary.counts
        } catch { snapshot.storageMessage = "Не удалось прочитать состояние индекса." }
        // Retain current data only if this read has not been overtaken.
        if snapshot.revision == state.revision { state = snapshot }
        for listener in listeners.values { listener.yield(snapshot) }
    }

    private func reconcile() async throws {
        try Task.checkCancellation()
        try await store.synchronizeEmbeddingDocuments()
        state.titles = try await store.embeddingDocumentTitles()
        let fm = FileManager.default
        var seen: Set<String> = []
        if fm.fileExists(atPath: root.path) {
            let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
            for folder in folders {
                try Task.checkCancellation()
                let flags = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard flags.isDirectory == true, flags.isSymbolicLink != true else { continue }
                let id = folder.lastPathComponent
                guard fm.fileExists(atPath: folder.appendingPathComponent("transcript.json").path) else { continue }
                seen.insert(id)
                let key = EmbeddingSourceKey(kind: .meeting, externalID: id)
                state.titles[key] = Self.meetingTitle(folder)
                do {
                    if try await reader.synchronize(meetingID: id, store: store) { state.sourceErrors.removeValue(forKey: key) }
                    else { reconcilePending = true }
                } catch { state.sourceErrors[key] = "Не удалось прочитать расшифровку. Проверьте файл или повторите распознавание." }
            }
        }
        for job in try await store.embeddingJobs() where job.source.kind == .meeting && !seen.contains(job.source.externalID) {
            try await store.removeEmbeddingSource(job.source)
            state.sourceErrors.removeValue(forKey: job.source)
        }
        for key in state.sourceErrors.keys where key.kind == .meeting && !seen.contains(key.externalID) {
            state.sourceErrors.removeValue(forKey: key)
        }
        state.storageMessage = nil
        await emit()
    }

    nonisolated private static func meetingTitle(_ folder: URL) -> String {
        let file = folder.appendingPathComponent("meta.json")
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), size.isSymbolicLink == false,
           (size.fileSize ?? Int.max) < 128_000, let data = try? Data(contentsOf: file),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let title = object["title"] as? String, !title.isEmpty { return title }
        return "Встреча \(folder.lastPathComponent)"
    }
}
