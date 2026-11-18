import Foundation
@available(macOS 15.0, *)
nonisolated final class ProbeTaskExecutor: TaskExecutor, @unchecked Sendable {
    private final class Queue: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [UnownedJob] = []
        private var stopping = false
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func enqueue(_ job: UnownedJob) {
            condition.lock(); defer { condition.unlock() }
            precondition(!stopping)
            jobs.append(job); condition.signal()
        }
        func next() -> UnownedJob? {
            condition.lock(); defer { condition.unlock() }
            while jobs.isEmpty && !stopping { condition.wait() }
            return jobs.isEmpty ? nil : jobs.removeFirst()
        }
        func complete() {
            condition.lock(); finished = true
            let pending = waiters; waiters.removeAll(); condition.unlock()
            pending.forEach { $0.resume() }
        }
        func close() async {
            await withCheckedContinuation { continuation in
                condition.lock(); stopping = true
                if finished { condition.unlock(); continuation.resume() }
                else { waiters.append(continuation); condition.broadcast(); condition.unlock() }
            }
        }
    }
    let id = UUID()
    private let queue = Queue()
    init() {
        let queue = queue, id = id, executor = asUnownedTaskExecutor()
        let thread = Thread {
            Thread.current.threadDictionary["golos56.executor"] = id.uuidString
            while let job = queue.next() { job.runSynchronously(on: executor) }
            queue.complete()
        }
        thread.name = "golos-migration-fixture-task"
        thread.qualityOfService = .default
        thread.start()
    }
    func enqueue(_ job: consuming ExecutorJob) { queue.enqueue(UnownedJob(job)) }
    func close() async { await queue.close() }
}
