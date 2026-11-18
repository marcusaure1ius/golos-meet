import Foundation

/// Independent utility worker: no encoder load, ASR or recording dependency.
/// Cancel/stop fences the durable lease before a late task can publish.
actor MeetingAssignmentWorker {
    typealias Calculate = @Sendable (String, MeetingAssignmentLease) async throws -> MeetingAssignmentCommit
    private let store: ProjectStore
    private let inputs: MeetingAssignmentInputReader
    private let calculate: Calculate
    private let timeout: Duration
    private var started = false
    private var indexAvailable: Bool
    private var reconcilePending = false
    private var worker: Task<Void, Never>?
    private var active: (lease: MeetingAssignmentLease, task: Task<MeetingAssignmentCommit, Error>)?
    private var cursor: String?
    private var request = UUID()
    private var deferred: [String: UUID] = [:]
    private var state = MeetingAssignmentRuntimeSnapshot()
    private var listeners: [UUID: AsyncStream<MeetingAssignmentRuntimeSnapshot>.Continuation] = [:]

    init(store: ProjectStore, meetingsRoot: URL, documentsRoot: URL, indexAvailable: Bool = false, timeout: Duration = .seconds(10), calculate: Calculate? = nil) {
        self.store = store; self.indexAvailable = indexAvailable; self.timeout = timeout
        inputs = MeetingAssignmentInputReader(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
        let engine = MeetingAssignmentService(store: store, meetingsRoot: meetingsRoot, documentsRoot: documentsRoot)
        self.calculate = calculate ?? { id, lease in
            guard let plan = try await engine.prepare(meetingID: id) else { return .manual }
            return try await engine.commit(plan, runtimeLease: lease)
        }
    }
    func updates() -> AsyncStream<MeetingAssignmentRuntimeSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MeetingAssignmentRuntimeSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[id] = continuation; continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }
    private func remove(_ id: UUID) { listeners.removeValue(forKey: id) }
    func start() async {
        guard !started else { return }
        started = true
        do {
            try await store.recoverAssignmentWork()
            if !indexAvailable { try await store.assignmentIndexUnavailable() }
        }
        catch { state.message = "Не удалось восстановить очередь распределения." }
        changed()
    }
    func setIndexAvailable(_ available: Bool) async {
        guard indexAvailable != available else { return }
        indexAvailable = available
        if !available {
            do { try await store.assignmentIndexUnavailable() }
            catch { state.message = "Не удалось сохранить недоступность модели распределения." }
            active?.task.cancel()
        }
        changed()
    }
    func changed() { request = UUID(); reconcilePending = true; if started { launch() } }
    func cancel(_ id: String) async {
        do {
            try await store.cancelAssignment(id)
            if active?.lease.work.meetingID == id { active?.task.cancel() }
        } catch { state.message = "Не удалось сохранить отмену распределения." }
        await emit()
    }
    func retry(_ id: String) async {
        do { try await store.retryAssignment(id); changed() }
        catch { state.message = "Не удалось повторить распределение." }
        await emit()
    }
    func stop() async {
        started = false
        if let active {
            // Invalidate before cancellation; cancellation itself is cooperative.
            do { try await store.interruptAssignment(active.lease) }
            catch { state.message = "Не удалось сохранить остановку распределения. Очередь восстановится при запуске." }
            active.task.cancel()
        }
        worker?.cancel()
        await emit()
    }
    func waitUntilIdle() async { while let task = worker { await task.value } }
    func snapshot() -> MeetingAssignmentRuntimeSnapshot { state }
    private func launch() {
        guard worker == nil else { return }
        worker = Task(priority: .utility) { await self.drain() }
    }
    private func drain() async {
        do {
            var conflicts = 0
            while started, !Task.isCancelled {
                if reconcilePending {
                    reconcilePending = false
                    // A previous status write can fail while SQLite is busy.
                    // With no active calculation, running rows are orphans.
                    try await store.recoverAssignmentWork()
                    let known = try await store.assignmentRuntimeSnapshot()
                    let raw = try await inputs.capture(additionalIDs: Set(known.work.keys))
                    let captured = indexAvailable ? raw : MeetingAssignmentInputs(checkpoint: raw.checkpoint,
                        fingerprints: raw.fingerprints.mapValues { $0 + "|runtime-unavailable" })
                    guard started, !Task.isCancelled else { break }
                    if try await store.reconcileAssignmentWork(captured) == false {
                        conflicts += 1
                        // Index updates/fallback will wake us. Do not spin while
                        // another actor continuously changes the catalog.
                        if conflicts >= 3 { break }
                        reconcilePending = true; await Task.yield(); continue
                    }
                    conflicts = 0; state.message = nil
                    await emit()
                }
                guard let lease = try await store.claimAssignmentWork(after: cursor, excluding: Set(deferred.filter { $0.value == request }.keys)) else { break }
                guard started, !Task.isCancelled else { try await store.interruptAssignment(lease); break }
                cursor = lease.work.meetingID
                await process(lease, request: request)
            }
        } catch is CancellationError {} catch {
            state.message = "Не удалось прочитать или сохранить очередь распределения. Повторите проверку."
        }
        worker = nil
        await emit()
        if started, reconcilePending, state.message == nil { launch() }
    }
    private func process(_ lease: MeetingAssignmentLease, request: UUID) async {
        guard indexAvailable else {
            await recordFailure(lease, state: .waiting, message: "Для распределения нужна работающая локальная модель индексирования.")
            await emit(); return
        }
        let calculate = calculate
        let task = Task(priority: .utility) { try await calculate(lease.work.meetingID, lease) }
        active = (lease, task)
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
                await recordFailure(lease, state: .failed, message: "Расчёт превысил 10 секунд. Можно повторить.")
                await emit()
                task.cancel()
            } catch {}
        }
        await emit()
        do {
            switch try await task.value {
            case .applied, .unchanged: break // Status committed with the links.
            case .manual: try await store.failAssignment(lease, state: .manual, message: "")
            case .superseded: await deferUntilChange(lease, request: request)
            }
        } catch is CancellationError {
            await recordFailure(lease, state: .failed, message: "Расчёт остановлен или превысил 10 секунд. Можно повторить.")
        } catch MeetingAssignmentError.stale {
            await deferUntilChange(lease, request: request)
        } catch MeetingAssignmentError.notReady {
            await recordFailure(lease, state: .waiting, message: MeetingAssignmentError.notReady.localizedDescription)
        } catch MeetingAssignmentError.limited {
            await recordFailure(lease, state: .failed, message: MeetingAssignmentError.limited.localizedDescription)
        } catch {
            await recordFailure(lease, state: .failed, message: "Не удалось проверить источники распределения. Исправьте источник или индекс и повторите.")
        }
        deadline.cancel(); active = nil
        await emit()
    }
    private func deferUntilChange(_ lease: MeetingAssignmentLease, request: UUID) async {
        do { try await store.interruptAssignment(lease, message: "Индекс изменяется. Повторим после его обновления.") }
        catch { state.message = "Не удалось сохранить повтор распределения." }
        // At most one attempt per external request. An index event received
        // during the old calculation immediately permits one fresh attempt.
        deferred[lease.work.meetingID] = request
    }
    private func recordFailure(_ lease: MeetingAssignmentLease, state: MeetingAssignmentWorkState, message: String) async {
        do { try await store.failAssignment(lease, state: state, message: message) }
        catch { self.state.message = "Не удалось сохранить состояние распределения. Повторите проверку после восстановления библиотеки." }
    }
    private func emit() async {
        state.revision += 1
        let revision = state.revision
        let message = state.message
        do {
            var current = try await store.assignmentRuntimeSnapshot()
            guard revision == state.revision else { return }
            current.revision = revision; current.message = message; state = current
        } catch { state.message = "Не удалось прочитать состояние распределения."; state.revision = revision }
        for listener in listeners.values { listener.yield(state) }
    }
}
