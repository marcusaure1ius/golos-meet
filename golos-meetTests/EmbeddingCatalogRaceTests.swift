import Foundation
import Testing
@testable import golos_meet

/// Two real SQLite connections and actual transcript rewrites. A scan retains
/// its observation while the second connection changes the catalog underneath.
@MainActor @Suite struct EmbeddingCatalogRaceTests {
    private func fixture() throws -> (URL, URL, Data, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-race-\(UUID())")
        let folder = root.appendingPathComponent("meetings/synthetic")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func bytes(_ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["meetingId": "synthetic", "segments": [
                ["start": 1, "end": 2, "text": text]
            ]], options: .sortedKeys)
        }
        return (root, folder.appendingPathComponent("transcript.json"), try bytes("Актуальная версия A"), try bytes("Промежуточная версия B"))
    }

    @Test func delayedScanAndInvalidationCannotCrossCatalogABAOrRecreation() async throws {
        let (root, file, a, b) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        let first = ProjectStore(url: url), other = ProjectStore(url: url)
        let reader = MeetingEmbeddingSnapshotReader(root: root.appendingPathComponent("meetings"))
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "synthetic")
        try a.write(to: file, options: .atomic)
        #expect(try await reader.synchronize(meetingID: "synthetic", store: first))
        let observedA = try await first.observeEmbeddingSource(key)
        try b.write(to: file, options: .atomic)
        let delayedB = try await reader.read(meetingID: "synthetic")
        #expect(try await reader.synchronize(meetingID: "synthetic", store: other))
        try a.write(to: file, options: .atomic)
        #expect(try await reader.synchronize(meetingID: "synthetic", store: other))
        let currentA = try await other.observeEmbeddingSource(key)
        #expect(observedA.revision == currentA.revision)
        #expect(observedA.generation != currentA.generation)
        let currentJob = try #require(try await other.embeddingJobs().first)
        #expect(try await first.synchronizeMeetingEmbedding(delayedB, replacing: observedA) == false)
        #expect(try await first.invalidateMeetingEmbedding(key, replacing: observedA) == false)
        #expect(try await other.observeEmbeddingSource(key) == currentA)
        #expect(try await other.embeddingJobs().first == currentJob)
        #expect(try Data(contentsOf: file) == a)

        // Delete and recreate exactly A. A stale invalidation must preserve the
        // new source, its pending job, chunks and the actual transcript bytes.
        let oldIncarnation = try await first.observeEmbeddingSource(key)
        try await other.removeEmbeddingSource(key)
        #expect(try await reader.synchronize(meetingID: "synthetic", store: other))
        let recreated = try await other.observeEmbeddingSource(key)
        let recreatedJob = try #require(try await other.embeddingJobs().first)
        #expect(recreated.revision == oldIncarnation.revision)
        #expect(recreated.generation != oldIncarnation.generation)
        #expect(try await first.invalidateMeetingEmbedding(key, replacing: oldIncarnation) == false)
        #expect(try await first.synchronizeMeetingEmbedding(delayedB, replacing: oldIncarnation) == false)
        #expect(try await other.observeEmbeddingSource(key) == recreated)
        #expect(try await other.embeddingJobs().first == recreatedJob)
        #expect(try Data(contentsOf: file) == a)
    }

    @Test func observedAbsenceCannotSurviveCreateDeleteOrAnotherRemoval() async throws {
        let (root, file, a, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        let first = ProjectStore(url: url), other = ProjectStore(url: url)
        let reader = MeetingEmbeddingSnapshotReader(root: root.appendingPathComponent("meetings"))
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "synthetic")
        let absent = try await first.observeEmbeddingSource(key)
        #expect(absent.revision == nil && !absent.generation.isEmpty)
        #expect(try await other.observeEmbeddingSource(key) == absent)
        try a.write(to: file, options: .atomic)
        let delayedA = try await reader.read(meetingID: "synthetic")
        #expect(try await reader.synchronize(meetingID: "synthetic", store: other))
        try await other.removeEmbeddingSource(key)
        let absentAgain = try await other.observeEmbeddingSource(key)
        #expect(absentAgain.revision == nil && absentAgain.generation != absent.generation)
        #expect(try await first.synchronizeMeetingEmbedding(delayedA, replacing: absent) == false)
        #expect(try await first.invalidateMeetingEmbedding(key, replacing: absent) == false)
        #expect(try await other.embeddingJobs().isEmpty)
        #expect(try await other.observeEmbeddingSource(key) == absentAgain)

        // A repeated remove of an absent source fences already-started scans too.
        try await other.removeEmbeddingSource(key)
        #expect(try await first.synchronizeMeetingEmbedding(delayedA, replacing: absentAgain) == false)
        let freshAbsence = try await first.observeEmbeddingSource(key)
        #expect(try await first.synchronizeMeetingEmbedding(delayedA, replacing: freshAbsence))
        #expect(try await first.invalidateMeetingEmbedding(key, replacing: freshAbsence) == false)
        let active = try await first.observeEmbeddingSource(key)
        #expect(try await first.invalidateMeetingEmbedding(key, replacing: active))
        #expect(try await first.invalidateMeetingEmbedding(key, replacing: active) == false)
        #expect(try Data(contentsOf: file) == a)
    }

    @Test func unchangedFingerprintAndJobLifecycleKeepCatalogObservationStable() async throws {
        let (root, file, a, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try a.write(to: file, options: .atomic)
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let reader = MeetingEmbeddingSnapshotReader(root: root.appendingPathComponent("meetings"))
        #expect(try await reader.synchronize(meetingID: "synthetic", store: store))
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "synthetic")
        let observed = try await store.observeEmbeddingSource(key)
        #expect(try await reader.synchronize(meetingID: "synthetic", store: store))
        try await store.activateEmbeddingModel(.init(id: "synthetic-catalog-only", dimensions: 2))
        _ = try #require(try await store.claimEmbeddingJob())
        try await store.cancelEmbeddingJob(key)
        try await store.retryEmbeddingJob(key)
        _ = try #require(try await store.claimEmbeddingJob())
        try await store.recoverEmbeddingJobs()
        #expect(try await store.observeEmbeddingSource(key) == observed)
    }
}
