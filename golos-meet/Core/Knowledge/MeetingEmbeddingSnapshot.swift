import Foundation
import CryptoKit

/// Reads transcript.json only. Audio and insights are never opened. The caller
/// supplies a root explicitly; production wiring is kept outside this reader.
actor MeetingEmbeddingSnapshotReader {
    private let root: URL
    init(root: URL) { self.root = root }

    func read(meetingID: String) throws -> EmbeddingSourceSnapshot {
        guard !meetingID.isEmpty, ![".", ".."].contains(meetingID),
              !meetingID.contains("/"), !meetingID.contains("\0") else { throw EmbeddingIndexError.invalidSource }
        let folder = root.appendingPathComponent(meetingID, isDirectory: true)
        let file = folder.appendingPathComponent("transcript.json")
        for item in [root, folder, file] {
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
                throw EmbeddingIndexError.invalidSource
            }
        }
        let size = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard size.isRegularFile == true, let count = size.fileSize, count > 0, count <= 50_000_000 else {
            throw EmbeddingIndexError.invalidTranscript
        }
        let data = try Data(contentsOf: file)
        guard data.count <= 50_000_000 else { throw EmbeddingIndexError.invalidTranscript }
        let transcript: IndexTranscript
        do { transcript = try JSONDecoder().decode(IndexTranscript.self, from: data) }
        catch { throw EmbeddingIndexError.invalidTranscript }
        guard transcript.meetingId == meetingID,
              transcript.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else {
            throw EmbeddingIndexError.invalidTranscript
        }
        let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = EmbeddingSourceKey(kind: .meeting, externalID: meetingID)
        let blocks = transcript.segments.compactMap { segment -> ExtractedTextBlock? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return .init(text: text, location: .init(startSeconds: segment.start, endSeconds: segment.end))
        }
        let document = ExtractedDocument(title: meetingID, contentHash: revision, blocks: blocks)
        let chunks = KnowledgeChunker.chunks(from: document, sourceID: key.chunkSourceID)
        guard !chunks.isEmpty else { throw EmbeddingIndexError.invalidTranscript }
        return .init(key: key, revision: revision, chunks: chunks)
    }

    /// A fresh file snapshot must be taken after observing the catalog revision.
    /// The CAS prevents a delayed scan from reverting a newer registered snapshot.
    @discardableResult
    func synchronize(meetingID: String, store: ProjectStore) async throws -> Bool {
        let key = EmbeddingSourceKey(kind: .meeting, externalID: meetingID)
        let expected = try await store.embeddingRevision(for: key)
        do {
            let snapshot = try read(meetingID: meetingID)
            return try await store.synchronizeMeetingEmbedding(snapshot, replacing: expected)
        } catch {
            // Invalid/missing new bytes must not leave the previous transcript
            // searchable. A delayed failed scan cannot remove a newer snapshot.
            try await store.invalidateMeetingEmbedding(key, replacing: expected)
            throw error
        }
    }

    private struct IndexTranscript: Decodable { let meetingId: String; let segments: [IndexSegment] }
    private struct IndexSegment: Decodable { let start: Double; let end: Double; let text: String }
}
