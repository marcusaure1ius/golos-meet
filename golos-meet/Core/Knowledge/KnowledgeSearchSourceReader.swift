import Foundation
import CryptoKit
import Darwin

actor KnowledgeSearchSourceReader {
    private let store: ProjectStore
    private let meetings: MeetingEmbeddingSnapshotReader
    private let documents: DocumentImporter
    private let meetingsRoot: URL
    private let documentsRoot: URL

    init(store: ProjectStore, meetingsRoot: URL, documentsRoot: URL) {
        self.store = store
        self.meetingsRoot = meetingsRoot
        self.documentsRoot = documentsRoot
        meetings = MeetingEmbeddingSnapshotReader(root: meetingsRoot)
        documents = DocumentImporter(store: store, root: documentsRoot)
    }

    func read(_ hit: KnowledgeSearchHit, includePDF: Bool) async throws -> (chunks: [KnowledgeChunk], pdf: Data?) {
        guard let stamp = hit.fileStamp, try await identity(hit.source) == stamp else { throw KnowledgeSearchError.sourceChanged }
        if hit.source.key.kind == .meeting {
            do {
                let snapshot = try await meetings.read(meetingID: hit.source.key.externalID)
                guard snapshot.revision == hit.source.observation.revision,
                      snapshot.chunks.contains(hit.chunk), try await identity(hit.source) == stamp else { throw KnowledgeSearchError.sourceChanged }
                return (snapshot.chunks, nil)
            } catch {
                // Invalidate stale searchable data using the same guarded reader
                // as indexing. Never publish the bytes of a failed read.
                _ = try? await meetings.synchronize(meetingID: hit.source.key.externalID, store: store)
                throw KnowledgeSearchError.sourceChanged
            }
        }
        guard let version = hit.source.document, version.id.uuidString == hit.source.observation.revision else { throw KnowledgeSearchError.sourceChanged }
        do {
            let file = try await documents.fileURL(for: version)
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize,
                  size > 0, size <= LocalDocumentExtractor.maximumBytes else { throw KnowledgeSearchError.sourceChanged }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256(), count = 0
            let capture = includePDF && URL(fileURLWithPath: version.relativePath).pathExtension.lowercased() == "pdf"
            var bytes = Data()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                count += data.count
                guard count <= LocalDocumentExtractor.maximumBytes else { throw KnowledgeSearchError.sourceChanged }
                hasher.update(data: data)
                if capture { bytes.append(data) }
            }
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hash == version.contentHash else { throw KnowledgeSearchError.sourceChanged }
            let chunks = try await store.chunks(for: version.id)
            guard chunks.contains(hit.chunk), try await identity(hit.source) == stamp else { throw KnowledgeSearchError.sourceChanged }
            return (chunks, capture ? bytes : nil)
        } catch is CancellationError { throw CancellationError() }
        catch { throw KnowledgeSearchError.sourceChanged }
    }

    /// inode/birth/ctime detects delete/recreate and in-place A→B→A even before
    /// FSEvents reconciliation. Hash validation still decides content identity.
    func identity(_ source: KnowledgeSearchSource) async throws -> String {
        let file: URL
        if source.key.kind == .document {
            guard let version = source.document else { throw KnowledgeSearchError.sourceChanged }
            file = try await documents.fileURL(for: version)
            let raw = documentsRoot.appendingPathComponent(version.relativePath)
            for item in [documentsRoot, documentsRoot.appendingPathComponent("documents"), raw.deletingLastPathComponent(), raw] {
                guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw KnowledgeSearchError.sourceChanged }
            }
        } else {
            let id = source.key.externalID
            guard !id.isEmpty, ![".", ".."].contains(id), !id.contains("/"), !id.contains("\0") else { throw KnowledgeSearchError.sourceChanged }
            let folder = meetingsRoot.appendingPathComponent(id)
            file = folder.appendingPathComponent("transcript.json")
            for item in [meetingsRoot, folder] {
                guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw KnowledgeSearchError.sourceChanged }
            }
        }
        var value = stat()
        guard lstat(file.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw KnowledgeSearchError.sourceChanged }
        return "\(value.st_dev):\(value.st_ino):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_size)"
    }

    func title(_ source: KnowledgeSearchSource) -> String {
        guard source.key.kind == .meeting else { return source.title }
        let id = source.key.externalID
        guard !id.isEmpty, ![".", ".."].contains(id), !id.contains("/"), !id.contains("\0") else { return source.title }
        let file = meetingsRoot.appendingPathComponent(id).appendingPathComponent("meta.json")
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let handle = try? FileHandle(forReadingFrom: file) else { return source.title }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 128_001), data.count <= 128_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String, !title.isEmpty else { return source.title }
        return title
    }
}
