import Foundation
import Testing
@testable import golos_meet

@MainActor @Suite struct MeetingEmbeddingSnapshotTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-embedding-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func bytes(_ text: String, start: Double = 12.5, end: Double = 21.25) throws -> Data {
        try JSONEncoder().encode(Transcript(meetingId: "synthetic-meeting", asrModel: "synthetic-no-audio",
            segments: [.init(start: start, end: end, speaker: .participants, text: text)]))
    }

    @Test func actualTranscriptABAUsesContentFingerprintAndKeepsTimecodesAndSharedIdentity() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let meetings = root.appendingPathComponent("meetings")
        let folder = meetings.appendingPathComponent("synthetic-meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("transcript.json")
        let original = try bytes("Запуск в декабре. Ответственная Анна.")
        let changed = try bytes("Запуск в январе. Ответственный Борис.", start: 15, end: 30)
        try original.write(to: file, options: .atomic)
        let reader = MeetingEmbeddingSnapshotReader(root: meetings)
        let store = ProjectStore(url: root.appendingPathComponent("library.sqlite"))
        let a = try await store.createProject(name: "А"), b = try await store.createProject(name: "Б")
        try await store.assignMeeting("synthetic-meeting", to: [a.id, b.id])
        let first = try await reader.read(meetingID: "synthetic-meeting")
        #expect(first.chunks.first?.location.startSeconds == 12.5)
        #expect(first.chunks.first?.location.endSeconds == 21.25)
        #expect(try await reader.synchronize(meetingID: "synthetic-meeting", store: store))
        let observedA = try await store.observeEmbeddingSource(first.key)
        let model = EmbeddingIndexModel(id: "synthetic-meeting-storage", dimensions: 2)
        try await store.activateEmbeddingModel(model)
        let old = try #require(try await store.claimEmbeddingJob())
        let computed = IndexedChunkVectors(chunkID: first.chunks[0].id, bodyTokenCount: 5, windows: [
            .init(tokenStart: 0, tokenCount: 5, vector: try KnowledgeVector(modelID: model.id, values: [1, 2]))
        ])
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        try changed.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        #expect(try await reader.synchronize(meetingID: "synthetic-meeting", store: store))
        let second = try await reader.read(meetingID: "synthetic-meeting")
        #expect(second.revision != first.revision)
        // A delayed old scan cannot undo B even before returning to A.
        #expect(try await store.synchronizeMeetingEmbedding(first, replacing: observedA) == false)
        try original.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        #expect(try await reader.synchronize(meetingID: "synthetic-meeting", store: store))
        #expect(try await store.embeddingRevision(for: first.key) == first.revision)
        #expect(try await store.publishEmbeddingVectors([computed], lease: old) == false)
        #expect(try await store.embeddingJobs().count == 1)
        #expect(try await store.snapshot().meetingProjects["synthetic-meeting"] == [a.id, b.id])
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["transcript.json"])
    }

    @Test func malformedDeletedAndSymlinkTranscriptsInvalidateDerivedCatalogWithoutEditingSource() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("synthetic-meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("transcript.json")
        let original = try bytes("Синтетическая расшифровка")
        try original.write(to: file)
        let reader = MeetingEmbeddingSnapshotReader(root: root)
        let store = ProjectStore(url: root.appendingPathComponent("library.sqlite"))
        #expect(try await reader.synchronize(meetingID: "synthetic-meeting", store: store))
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "synthetic-meeting")
        let bad = Data("{invalid".utf8)
        try bad.write(to: file)
        await #expect(throws: EmbeddingIndexError.invalidTranscript) { try await reader.synchronize(meetingID: "synthetic-meeting", store: store) }
        #expect(try await store.embeddingRevision(for: key) == nil)
        #expect(try Data(contentsOf: file) == bad)
        try original.write(to: file)
        #expect(try await reader.synchronize(meetingID: "synthetic-meeting", store: store))
        try FileManager.default.removeItem(at: file)
        await #expect(throws: EmbeddingIndexError.self) { try await reader.synchronize(meetingID: "synthetic-meeting", store: store) }
        #expect(try await store.embeddingJobs().isEmpty)
        let external = root.appendingPathComponent("external.json")
        try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        await #expect(throws: EmbeddingIndexError.invalidSource) { try await reader.read(meetingID: "synthetic-meeting") }
        #expect(try Data(contentsOf: external) == original)
        await #expect(throws: EmbeddingIndexError.invalidSource) { try await reader.read(meetingID: "../external.json") }
    }
}
