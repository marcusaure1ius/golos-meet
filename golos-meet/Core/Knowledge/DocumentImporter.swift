import Foundation
import CryptoKit

typealias DocumentExtractionWork = @Sendable (URL, @escaping @Sendable (Int, Int) -> Void) async throws -> ExtractedDocument

/// Serial background work, independent of MeetingProcessor and the ASR sidecar.
/// Documents never enter a network client; all parsing receives the staged copy.
actor DocumentImporter {
    static let supportedExtensions: Set<String> = ["txt", "md", "markdown", "docx", "pdf", "png", "jpg", "jpeg", "tif", "tiff", "heic"]
    private let store: ProjectStore
    private let root: URL
    private let extract: DocumentExtractionWork

    init(store: ProjectStore, root: URL, extract: DocumentExtractionWork? = nil) {
        self.store = store
        self.root = root
        let extractor = LocalDocumentExtractor()
        self.extract = extract ?? { url, progress in try await extractor.extract(from: url, progress: progress) }
    }

    func importFile(id: UUID, url: URL, projectIDs: Set<UUID>, targetID: UUID? = nil,
                    progress: @escaping @Sendable (DocumentImportProgress) -> Void) async throws -> DocumentImportResult {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging/\(id.uuidString)", isDirectory: true)
        let versionID = UUID()
        let versionDirectory = root.appendingPathComponent("documents/\(versionID.uuidString)", isDirectory: true)
        var installed = false
        var committed = false
        var reused = false
        defer {
            try? fm.removeItem(at: staging)
            if installed && (!committed || reused) { try? fm.removeItem(at: versionDirectory) }
        }
        do {
            try Task.checkCancellation()
            try await store.startImport(id: id, filename: url.lastPathComponent, targetID: targetID)
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { throw DocumentExtractionError.unsupportedFormat(ext) }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let stagedFile = staging.appendingPathComponent("original.\(ext)")
            progress(.init(state: .copying))
            let hash = try copyBounded(from: url, to: stagedFile, progress: progress)
            // External viewers should offer Save As instead of editing an indexed
            // revision in place. Updates go through the explicit import action.
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: stagedFile.path)
            try Task.checkCancellation()
            let matchedID = try await store.matchingDocument(contentHash: hash)
            let documentID = targetID ?? matchedID ?? UUID()
            let alreadyKnown: Bool
            if let targetID { alreadyKnown = try await store.versions(for: targetID).contains { $0.contentHash == hash } }
            else { alreadyKnown = matchedID != nil }
            let extracted: ExtractedDocument
            if alreadyKnown {
                extracted = ExtractedDocument(title: url.deletingPathExtension().lastPathComponent, contentHash: hash, blocks: [])
            } else {
                try await store.updateImport(id: id, state: .extracting)
                progress(.init(state: .extracting))
                extracted = try await extract(stagedFile) { completed, total in
                    progress(.init(state: .extracting, completed: completed, total: total))
                }
                // Preserve the user-visible original name rather than "original".
                guard extracted.contentHash == hash else { throw DocumentImportError.invalidRecord }
            }
            try Task.checkCancellation()
            let named = ExtractedDocument(title: url.deletingPathExtension().lastPathComponent,
                                          contentHash: hash, blocks: extracted.blocks, warnings: extracted.warnings)
            try await store.updateImport(id: id, state: .indexing)
            progress(.init(state: .indexing))
            let chunks = KnowledgeChunker.chunks(from: named, sourceID: documentID)
            try Task.checkCancellation()
            if !alreadyKnown {
                guard !chunks.isEmpty else { throw DocumentExtractionError.noText }
                try fm.createDirectory(at: root.appendingPathComponent("documents", isDirectory: true), withIntermediateDirectories: true)
                try fm.moveItem(at: staging, to: versionDirectory)
                installed = true
            }
            let version = DocumentVersion(id: versionID, documentID: documentID, contentHash: hash,
                relativePath: "documents/\(versionID.uuidString)/original.\(ext)", originalName: url.lastPathComponent,
                importedAt: Date(), warnings: named.warnings, chunkCount: chunks.count)
            try await store.updateImport(id: id, state: .saving)
            progress(.init(state: .saving))
            let result = try await store.commitImport(attemptID: id, documentID: documentID, targetID: targetID,
                projectIDs: projectIDs, extracted: named, version: version, chunks: chunks)
            committed = true
            reused = result.reused
            return result
        } catch {
            let state: DocumentImportState = error is CancellationError ? .cancelled : .failed
            try? await store.updateImport(id: id, state: state, message: error is CancellationError ? "Импорт отменён; прежняя версия сохранена." : Self.userMessage(for: error))
            throw error
        }
    }

    /// History rows are user-facing: raw framework errors (e.g. Vision's
    /// CRImageReaderError) fall back to English exception text like
    /// "The operation couldn't be completed. (... error 1.)" — replace that with
    /// an honest Russian reason (issue #101).
    nonisolated static func userMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        return "Не удалось импортировать документ. Проверьте файл и повторите попытку."
    }

    /// Strictly derived paths avoid opening arbitrary locations from a damaged DB.
    func fileURL(for version: DocumentVersion) throws -> URL {
        let parts = version.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "documents", parts[1] == Substring(version.id.uuidString),
              parts[2].hasPrefix("original."), Self.supportedExtensions.contains(String(parts[2].dropFirst(9))) else {
            throw DocumentImportError.unsafePath
        }
        let file = root.appendingPathComponent(version.relativePath).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw DocumentImportError.unsafePath }
        return file
    }

    private func copyBounded(from source: URL, to destination: URL,
                             progress: @Sendable (DocumentImportProgress) -> Void) throws -> String {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw DocumentExtractionError.invalidDocument }
        guard let total = values.fileSize, total <= LocalDocumentExtractor.maximumBytes else { throw DocumentExtractionError.fileTooLarge }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var copied = 0
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            copied += data.count
            guard copied <= LocalDocumentExtractor.maximumBytes else { throw DocumentExtractionError.fileTooLarge }
            try output.write(contentsOf: data)
            hasher.update(data: data)
            progress(.init(state: .copying, completed: copied, total: max(total, copied)))
        }
        try output.synchronize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
