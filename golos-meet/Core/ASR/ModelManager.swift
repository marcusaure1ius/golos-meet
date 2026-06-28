import Foundation
import Combine
import CryptoKit

/// Состояние одной загрузки.
struct ModelDownloadProgress: Equatable {
    let bytesDownloaded: Int64
    let bytesTotal: Int64
    var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(bytesTotal)
    }
}

/// Описание одной модели (несколько файлов в одном bundle).
struct ModelDescriptor {
    let id: String              // "e2e_rnnt" или "e2e_ctc"
    let displayName: String     // "Качество" / "Скорость"
    let files: [ModelFile]      // model.onnx, vocab.txt, ...
}

struct ModelFile {
    let url: URL
    let relativePath: String
    let sha256: String?         // optional verification
    let sizeBytes: Int64?       // nil = неизвестно до загрузки
}

@MainActor
class ModelManager: ObservableObject {
    @Published private(set) var progress: ModelDownloadProgress?
    @Published private(set) var error: String?

    /// Каталог конкретной модели.
    func modelDir(_ id: String) -> URL {
        AppPaths.modelDir(id)
    }

    /// Установлена ли модель локально (все файлы существуют; размер проверяется только если известен).
    func isInstalled(_ desc: ModelDescriptor) -> Bool {
        let dir = modelDir(desc.id)
        for f in desc.files {
            let path = dir.appendingPathComponent(f.relativePath)
            guard FileManager.default.fileExists(atPath: path.path) else { return false }
            if let expected = f.sizeBytes,
               let attr = try? FileManager.default.attributesOfItem(atPath: path.path),
               let size = attr[.size] as? Int64,
               size != expected {
                return false
            }
        }
        return true
    }

    func surfaceError(_ message: String) { error = message }

    func download(_ desc: ModelDescriptor) async throws {
        error = nil
        do {
            let dir = modelDir(desc.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let knownTotal = desc.files.compactMap(\.sizeBytes).reduce(0, +)
            progress = ModelDownloadProgress(bytesDownloaded: 0, bytesTotal: knownTotal)

            for f in desc.files {
                let dest = dir.appendingPathComponent(f.relativePath)
                try await downloadFile(f, to: dest, onChunk: { chunkSize in
                    Task { @MainActor [weak self] in
                        guard let self, let p = self.progress else { return }
                        self.progress = .init(bytesDownloaded: p.bytesDownloaded + Int64(chunkSize),
                                              bytesTotal: p.bytesTotal)
                    }
                })
            }
            progress = nil
        } catch {
            self.error = error.localizedDescription
            progress = nil
            throw error
        }
    }

    private func downloadFile(_ file: ModelFile, to dest: URL, onChunk: @escaping (Int) -> Void) async throws {
        let existing = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        if let expected = file.sizeBytes, existing == expected {
            // Уже скачано полностью.
            return
        }

        var req = URLRequest(url: file.url)
        for (k, v) in Self.makeResumeHeaders(existingBytes: existing) {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ModelManager", code: -1)
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw NSError(domain: "ModelManager", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }

        let appending = (http.statusCode == 206)
        let contentLength = http.expectedContentLength  // -1 если неизвестно
        if !appending, contentLength > 0 {
            // Обновим total если был unknown.
            Task { @MainActor [weak self] in
                guard let self, let p = self.progress else { return }
                let baseTotal = (p.bytesTotal == 0) ? contentLength : p.bytesTotal
                self.progress = .init(bytesDownloaded: p.bytesDownloaded, bytesTotal: baseTotal)
            }
        }
        if !appending {
            FileManager.default.createFile(atPath: dest.path, contents: nil)
        } else if !FileManager.default.fileExists(atPath: dest.path) {
            FileManager.default.createFile(atPath: dest.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: dest)
        if appending { try handle.seekToEnd() }
        defer { try? handle.close() }

        var hasher = SHA256()
        var buffer = Data(capacity: 8 * 1024)
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                hasher.update(data: buffer)
                onChunk(buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            onChunk(buffer.count)
        }

        if let expected = file.sha256 {
            // SHA проверка корректна только при полной (не resume) загрузке.
            if existing == 0 {
                let got = Self.bytesToHex(Data(hasher.finalize()))
                if got != expected {
                    try? FileManager.default.removeItem(at: dest)
                    throw NSError(domain: "ModelManager", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: "sha256 mismatch: \(got) vs \(expected)"])
                }
            }
        }
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return bytesToHex(Data(digest))
    }

    nonisolated static func bytesToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func makeResumeHeaders(existingBytes: Int64) -> [String: String] {
        guard existingBytes > 0 else { return [:] }
        return ["Range": "bytes=\(existingBytes)-"]
    }
}

// MARK: Конкретные модели GigaAM-v3

extension ModelDescriptor {
    static let asrModelId = "gigaam-v3"
    /// GigaAM-v3 ONNX bundle. URL'ы/размеры уточняются на этапе наполнения
    /// (см. spec §9). Структура — как в golos.
    static let gigaam = ModelDescriptor(
        id: asrModelId,
        displayName: "GigaAM-v3",
        files: [
            ModelFile(url: URL(string: "https://huggingface.co/istupakov/onnx-asr/resolve/main/gigaam-v3-rnnt/model.onnx")!,
                      relativePath: "model.onnx", sha256: nil, sizeBytes: nil),
            ModelFile(url: URL(string: "https://huggingface.co/istupakov/onnx-asr/resolve/main/gigaam-v3-rnnt/vocab.txt")!,
                      relativePath: "vocab.txt", sha256: nil, sizeBytes: nil),
        ])
}
