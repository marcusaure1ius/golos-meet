import Foundation

/// Serializes accepted real-time buffers in their callback order.
/// Closing atomically rejects late buffers, then awaits all accepted writes.
nonisolated final class PCMWriteSink: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: WavWriter
    private let onFailure: @Sendable () -> Void
    private var tail: Task<Void, Never>?
    private var accepting = true
    private var reportedFailure = false

    init(writer: WavWriter, onFailure: @escaping @Sendable () -> Void) {
        self.writer = writer
        self.onFailure = onFailure
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }
        let previous = tail
        let writer = writer
        tail = Task { [weak self] in
            await previous?.value
            if await !writer.append(data) { self?.failed() }
        }
    }

    private func failed() {
        lock.lock()
        let report = !reportedFailure
        reportedFailure = true
        lock.unlock()
        if report { onFailure() }
    }

    private func closeAndTakeTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        accepting = false
        return tail
    }

    func close() async { await closeAndTakeTail()?.value }
}
