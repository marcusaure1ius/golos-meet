import Foundation
import os

/// Источник транскрипции по файлу. Абстракция для подмены в тестах пайплайна.
protocol ASRClient {
    /// Транскрибировать WAV целиком, вернуть сегменты с таймкодами.
    func transcribe(fileURL: URL) async throws -> [TimedSegment]
}

/// Клиент вендоренного `golos-asr` sidecar для batch-режима.
/// Один процесс: hello → load → (transcribe_file)* → shutdown.
actor LocalASR: ASRClient {
    private let sidecarURL: URL
    private let modelDir: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [UInt64: CheckedContinuation<SidecarResponse, Error>] = [:]
    private var helloWaiter: CheckedContinuation<Void, Error>?
    private var helloReceived = false
    private var counter: UInt64 = 0

    init(sidecarURL: URL = AppPaths.sidecarBinary, modelDir: URL) {
        self.sidecarURL = sidecarURL
        self.modelDir = modelDir
    }

    /// Поднять процесс и загрузить модель.
    func start() async throws {
        try spawn()
        try await waitHello(timeout: 5)
        let resp = try await roundtrip(timeout: 180) { .load(id: $0, modelPath: modelDir.path) }
        switch resp {
        case .ready: return
        case .error(_, _, let m): throw ASRError.modelLoadFailed(m)
        default: throw ASRError.protocolError("after load: \(resp)")
        }
    }

    func transcribe(fileURL: URL) async throws -> [TimedSegment] {
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
        stdin?.closeFile(); stdin = nil
        let proc = process
        process = nil
        await Task.detached { proc?.waitUntilExit() }.value
        for (_, c) in pending { c.resume(throwing: ASRError.sidecarNotRunning) }
        pending.removeAll()
    }

    // MARK: private
    private func next() -> UInt64 { counter &+= 1; return counter }

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
        try proc.run()
        process = proc
        stdin = inPipe.fileHandleForWriting

        let out = outPipe.fileHandleForReading
        Task.detached { [weak self] in
            let dec = JSONDecoder()
            for try await line in out.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let resp = try? dec.decode(SidecarResponse.self, from: data) else { continue }
                await self?.deliver(resp)
            }
        }
        let err = errPipe.fileHandleForReading
        Task.detached { for try await l in err.bytes.lines { Log.sidecar.debug("\(l, privacy: .public)") } }
    }

    private func send(_ req: SidecarRequest) throws {
        guard let h = stdin else { throw ASRError.sidecarNotRunning }
        var data = try JSONEncoder().encode(req); data.append(0x0A)
        try h.write(contentsOf: data)
    }
}
