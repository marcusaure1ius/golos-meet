import Foundation
import os

/// Источник транскрипции по файлу. Абстракция для подмены в тестах пайплайна.
protocol ASRClient {
    /// Транскрибировать WAV целиком, вернуть сегменты с таймкодами.
    func transcribe(fileURL: URL) async throws -> [TimedSegment]
}

/// Накопитель байтов из stdout/stderr sidecar.
/// Доступ строго сериализован (вызывается с приватной очереди `readabilityHandler`),
/// поэтому `@unchecked Sendable` безопасен.
private final class LineAccumulator: @unchecked Sendable {
    private var buffer = Data()

    /// Добавить порцию байтов, вернуть все завершённые строки (без `\n`).
    func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            lines.append(line)
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}

/// Клиент вендоренного `golos-asr` sidecar для batch-режима.
/// Один процесс: hello → load → (transcribe_file)* → shutdown.
actor LocalASR: ASRClient {
    private let sidecarURL: URL
    private let engine: ASREngine
    private let modelPath: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var pending: [UInt64: CheckedContinuation<SidecarResponse, Error>] = [:]
    private var helloWaiter: CheckedContinuation<Void, Error>?
    private var helloReceived = false
    private var terminated = false
    private var counter: UInt64 = 0

    init(sidecarURL: URL = AppPaths.sidecarBinary, engine: ASREngine, modelPath: URL) {
        self.sidecarURL = sidecarURL
        self.engine = engine
        self.modelPath = modelPath
    }

    /// Удобный инициализатор по пользовательскому выбору модели.
    static func forChoice(_ c: ASRModelChoice) -> LocalASR {
        LocalASR(engine: c.engine, modelPath: c.modelPath)
    }

    /// Поднять процесс и загрузить модель.
    func start() async throws {
        try spawn()
        try await waitHello(timeout: 5)
        let resp = try await roundtrip(timeout: 180) { .load(id: $0, modelPath: modelPath.path, kind: engine) }
        switch resp {
        case .ready: return
        case .error(_, _, let m): throw ASRError.modelLoadFailed(m)
        default: throw ASRError.protocolError("after load: \(resp)")
        }
    }

    func transcribe(fileURL: URL) async throws -> [TimedSegment] {
        if process == nil { try await start() }
        let resp = try await roundtrip(timeout: 3600) { .transcribeFile(id: $0, path: fileURL.path) }
        switch resp {
        case .segments(_, let segs, _): return segs
        case .error(_, _, let m): throw ASRError.transcribeFailed(m)
        default: throw ASRError.protocolError("after transcribe_file: \(resp)")
        }
    }

    func shutdown() async {
        if let c = helloWaiter { helloWaiter = nil; c.resume(throwing: ASRError.sidecarNotRunning) }
        let id = next()
        try? send(.shutdown(id: id))
        // Снимаем readabilityHandler'ы — иначе фоновые источники продолжат жить.
        stdout?.readabilityHandler = nil; stdout = nil
        stderr?.readabilityHandler = nil; stderr = nil
        stdin?.closeFile(); stdin = nil
        let proc = process
        process = nil
        // Sidecar может не получить EOF / проигнорировать shutdown → принудительно
        // завершаем и ждём ограниченное время, чтобы не зависнуть навсегда.
        proc?.terminate()
        await boundedWait(proc, seconds: 2)
        for (_, c) in pending { c.resume(throwing: ASRError.sidecarNotRunning) }
        pending.removeAll()
    }

    // MARK: private
    private func next() -> UInt64 { counter &+= 1; return counter }

    /// Ждать завершения процесса не дольше `seconds`; блокирующий `waitUntilExit`
    /// выполняется в detached-задаче, чтобы не занимать кооперативный пул.
    private func boundedWait(_ proc: Process?, seconds: TimeInterval) async {
        guard let proc else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Task.detached { proc.waitUntilExit() }.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            await group.next()
            group.cancelAll()
        }
    }

    private func roundtrip(timeout: TimeInterval,
                           _ make: (UInt64) -> SidecarRequest) async throws -> SidecarResponse {
        let id = next()
        try send(make(id))
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); expire(id) }
        }
    }

    private func expire(_ id: UInt64) {
        if let c = pending.removeValue(forKey: id) { c.resume(throwing: ASRError.timeout) }
    }

    private func deliver(_ resp: SidecarResponse) {
        if case .hello = resp {
            helloReceived = true
            if let c = helloWaiter { helloWaiter = nil; c.resume() }
            return
        }
        guard let id = resp.id, let c = pending.removeValue(forKey: id) else { return }
        c.resume(returning: resp)
    }

    /// Процесс sidecar умер — завершаем все ожидающие continuations с ошибкой,
    /// чтобы они не висели до своего (длинного) таймаута.
    private func handleTermination() {
        guard !terminated else { return }
        terminated = true
        if let c = helloWaiter { helloWaiter = nil; c.resume(throwing: ASRError.sidecarNotRunning) }
        let waiters = pending
        pending.removeAll()
        for (_, c) in waiters { c.resume(throwing: ASRError.sidecarNotRunning) }
    }

    private func waitHello(timeout: TimeInterval) async throws {
        if helloReceived { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            helloWaiter = cont
            Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); expireHello() }
        }
    }

    private func expireHello() {
        if let c = helloWaiter { helloWaiter = nil; c.resume(throwing: ASRError.timeout) }
    }

    private func spawn() throws {
        let proc = Process()
        proc.executableURL = sidecarURL
        proc.arguments = []          // batch-режим: без --audio-path
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Смерть процесса должна немедленно провалить ожидающие continuations.
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        try proc.run()
        process = proc
        terminated = false
        stdin = inPipe.fileHandleForWriting

        // Неблокирующее чтение stdout: readabilityHandler вызывается на приватной
        // фоновой очереди, не занимая кооперативный пул Swift Concurrency (иначе
        // блокирующие read() голодают actor и continuations не резолвятся).
        let outHandle = outPipe.fileHandleForReading
        stdout = outHandle
        let outAcc = LineAccumulator()
        let dec = JSONDecoder()
        outHandle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }   // EOF
            for line in outAcc.append(data) {
                guard let resp = try? dec.decode(SidecarResponse.self, from: line) else { continue }
                Task { await self?.deliver(resp) }
            }
        }

        // stderr → Log.sidecar.debug, тоже неблокирующе и построчно.
        let errHandle = errPipe.fileHandleForReading
        stderr = errHandle
        let errAcc = LineAccumulator()
        errHandle.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            for line in errAcc.append(data) {
                let s = String(decoding: line, as: UTF8.self)
                Log.sidecar.debug("\(s, privacy: .public)")
            }
        }
    }

    private func send(_ req: SidecarRequest) throws {
        guard let h = stdin else { throw ASRError.sidecarNotRunning }
        var data = try JSONEncoder().encode(req); data.append(0x0A)
        try h.write(contentsOf: data)
    }
}
