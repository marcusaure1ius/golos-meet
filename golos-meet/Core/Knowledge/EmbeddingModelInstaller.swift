import Foundation
import CryptoKit

nonisolated struct EmbeddingInstallProgress: Sendable {
    let message: String
    let fraction: Double?
}

/// Progress contains byte counts only, never source texts or local paths.
nonisolated private final class EmbeddingDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let report: @Sendable (Int64) -> Void
    let limit: Int64
    init(limit: Int64, report: @escaping @Sendable (Int64) -> Void) { self.limit = limit; self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit { downloadTask.cancel() }
        report(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

actor EmbeddingModelInstaller {
    typealias Reporter = @Sendable (EmbeddingInstallProgress) -> Void
    typealias Validator = @Sendable (URL) async throws -> Void
    private let root: URL
    private let manifest: EmbeddingModelManifest
    private let validateRuntime: Validator
    private var busy = false

    init(root: URL, manifest: EmbeddingModelManifest = .e5Small,
         validateRuntime: @escaping Validator = { folder in
             let encoder = try await E5TextEmbedding(folder: folder)
             _ = try await encoder.embed(["Проверка локальной модели"], purpose: .query)
         }) {
        self.root = root; self.manifest = manifest; self.validateRuntime = validateRuntime
    }

    /// Restoring an installed model is local-only and rechecks integrity. A mere
    /// marker or matching file size never means that a model is ready.
    func installedFolder() throws -> URL? {
        let pointer = root.appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let active = try JSONDecoder().decode(Active.self, from: Data(contentsOf: pointer))
        guard active.modelID == manifest.modelID, UUID(uuidString: active.directory) != nil else {
            throw EmbeddingModelError.incompatibleModel
        }
        let folder = root.appendingPathComponent(active.directory, isDirectory: true)
        try verifyFolder(folder)
        return folder
    }

    /// Copy and download use the same staging, verification and atomic activation.
    /// The chosen external folder is never modified and is not needed afterwards.
    func install(from source: URL?, report: @escaping Reporter) async throws -> URL {
        guard !busy else { throw EmbeddingModelError.busy }
        busy = true
        defer { busy = false }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".install-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        var completed: Int64 = 0
        for asset in manifest.assets {
            try Task.checkCancellation()
            let destination = stage.appendingPathComponent(asset.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = completed
            let progress: @Sendable (Int64) -> Void = { bytes in
                report(.init(message: source == nil ? "Загружаем файлы модели…" : "Копируем файлы модели…",
                             fraction: min(1, Double(base + bytes) / Double(self.manifest.totalBytes))))
            }
            if let source {
                let file = source.appendingPathComponent(asset.path)
                try Self.requireRegularFile(file, inside: source, expectedBytes: asset.bytes)
                try Self.copy(file, to: destination, progress: progress)
            } else {
                let delegate = EmbeddingDownloadProgress(limit: asset.bytes, report: progress)
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: manifest.url(for: asset))
                request.setValue("GolosMeet-LocalModel/1", forHTTPHeaderField: "User-Agent")
                progress(0)
                let (temporary, response) = try await session.download(for: request)
                defer { try? fm.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme == "https" else {
                    throw EmbeddingModelError.download((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                try fm.moveItem(at: temporary, to: destination)
            }
            report(.init(message: "Проверяем \(asset.path)…", fraction: nil))
            try Self.verify(destination, inside: stage, asset: asset)
            completed += asset.bytes
        }
        try Task.checkCancellation()
        report(.init(message: "Проверяем работу модели на этом Mac…", fraction: nil))
        try await validateRuntime(stage)
        try Task.checkCancellation()
        let directory = UUID().uuidString
        let installed = root.appendingPathComponent(directory, isDirectory: true)
        try fm.moveItem(at: stage, to: installed)
        do {
            let active = Active(modelID: manifest.modelID, directory: directory)
            try JSONEncoder().encode(active).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: installed)
            throw error
        }
        // Previous versions are intentionally retained: outstanding readers may
        // still hold their files. No destructive cleanup during activation.
        return installed
    }

    func verifyFolder(_ folder: URL) throws {
        for asset in manifest.assets { try Self.verify(folder.appendingPathComponent(asset.path), inside: folder, asset: asset) }
    }

    nonisolated private static func requireRegularFile(_ file: URL, inside folder: URL, expectedBytes: Int64) throws {
        let fm = FileManager.default
        // Reject symlinks in the selected root and every descendant component.
        var current = file
        while current.path.count >= folder.path.count {
            let attributes = try? fm.attributesOfItem(atPath: current.path)
            guard let attributes, attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw EmbeddingModelError.invalidFile(file.lastPathComponent)
            }
            if current == folder { break }
            current.deleteLastPathComponent()
        }
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, Int64(values?.fileSize ?? -1) == expectedBytes else {
            throw EmbeddingModelError.invalidFile(file.lastPathComponent)
        }
    }

    nonisolated private static func verify(_ file: URL, inside folder: URL, asset: EmbeddingModelAsset) throws {
        try requireRegularFile(file, inside: folder, expectedBytes: asset.bytes)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == asset.sha256 else { throw EmbeddingModelError.invalidFile(asset.path) }
    }

    nonisolated private static func copy(_ source: URL, to target: URL, progress: @Sendable (Int64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var count: Int64 = 0
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            count += Int64(data.count)
            progress(count)
        }
    }

    private struct Active: Codable { let modelID: String; let directory: String }
}
