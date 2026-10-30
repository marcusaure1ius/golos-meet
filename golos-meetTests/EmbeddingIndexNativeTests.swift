import Foundation
import AppKit
import Testing
@testable import golos_meet

private actor NativeIndexSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { signalled = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

/// Real native encoder + actual local imports/transcript files + SQLite BLOBs.
/// No encoder mocks, Python inference, downloads, audio or user data.
@MainActor @Suite(.serialized) struct EmbeddingIndexNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLOS_MEET_E5_FOLDER"] != nil))
    func persistsRealDocumentAndMeetingWindowsAndRejectsFilesystemChangesDuringCalculation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-embedding-index-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GOLOS_MEET_E5_FOLDER"]))
        let encoder = try await E5TextEmbedding(folder: folder)
        let dbURL = root.appendingPathComponent("library.sqlite")
        let store = ProjectStore(url: dbURL)
        let importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
        let a = try await store.createProject(name: "А"), b = try await store.createProject(name: "Б")
        let textFile = root.appendingPathComponent("Unicode.txt")
        let originalText = Data(("Запуск проекта в декабре. " + String(repeating: "漢字🧪 ", count: 450)).utf8)
        try originalText.write(to: textFile)
        let imported = try await importer.importFile(id: UUID(), url: textFile, projectIDs: [a.id, b.id]) { _ in }
        let document = try #require(try await store.documents().first)
        let pdf = root.appendingPathComponent("План.pdf")
        try makePDF(pdf)
        let originalPDF = try Data(contentsOf: pdf)
        _ = try await importer.importFile(id: UUID(), url: pdf, projectIDs: [a.id]) { _ in }
        let meetings = root.appendingPathComponent("meetings")
        let meeting = meetings.appendingPathComponent("synthetic-meeting")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let transcriptFile = meeting.appendingPathComponent("transcript.json")
        let transcriptA = try transcript("Анна согласовала запуск проекта в декабре.")
        try transcriptA.write(to: transcriptFile, options: .atomic)
        let reader = MeetingEmbeddingSnapshotReader(root: meetings)
        #expect(try await reader.synchronize(meetingID: "synthetic-meeting", store: store))
        try await store.assignMeeting("synthetic-meeting", to: [a.id, b.id])
        try await store.activateEmbeddingModel(.e5Small)

        var sources = 0, hasMultipleWindows = false, hasPage = false, hasTime = false
        while let lease = try await store.claimEmbeddingJob() {
            let results = try await compute(lease, encoder: encoder)
            hasMultipleWindows = hasMultipleWindows || results.contains { $0.windows.count > 1 }
            #expect(try await store.publishEmbeddingVectors(results, lease: lease))
            let stored = try await ProjectStore(url: dbURL).embeddingWindows(for: lease.job.source, model: .e5Small)
            #expect(stored.count == results.reduce(0) { $0 + $1.windows.count })
            #expect(stored.allSatisfy { $0.vector.values.count == 384 && $0.vector.modelID == encoder.modelID && $0.revision == lease.snapshot.revision })
            for result in results {
                let windows = stored.filter { $0.chunk.id == result.chunkID }
                #expect(windows.first?.tokenStart == 0)
                #expect(windows.last.map { $0.tokenStart + $0.tokenCount } == result.bodyTokenCount)
                #expect(try windows[0].vector.cosineSimilarity(to: result.windows[0].vector) > 0.99999)
            }
            hasPage = hasPage || stored.contains { $0.chunk.location.page == 1 }
            hasTime = hasTime || stored.contains { $0.chunk.location.startSeconds == 12.5 && $0.chunk.location.endSeconds == 23.75 }
            sources += 1
        }
        #expect(sources == 3 && hasMultipleWindows && hasPage && hasTime)
        #expect(try await store.embeddingJobs().allSatisfy { $0.state == .ready })

        // Hold after the first real chunk, rewrite the actual source A→B→A,
        // then finish the remaining native calculations. Same version ID is
        // insufficient: generation/lease must reject the late result.
        let docKey = EmbeddingSourceKey(kind: .document, externalID: imported.documentID.uuidString)
        try await store.requestEmbeddingReindex(docKey)
        let docLease = try #require(try await store.claimEmbeddingJob())
        let reached = NativeIndexSignal(), release = NativeIndexSignal()
        let lateDocument = Task {
            do {
                let result = try await compute(docLease, encoder: encoder) {
                    await reached.signal(); await release.wait()
                }
                return try await store.publishEmbeddingVectors(result, lease: docLease)
            } catch { await reached.signal(); throw error }
        }
        await reached.wait()
        try Data("Новая версия: запуск в январе, ответственный Борис.".utf8).write(to: textFile)
        _ = try await importer.importFile(id: UUID(), url: textFile, projectIDs: [], targetID: document.id) { _ in }
        try originalText.write(to: textFile)
        _ = try await importer.importFile(id: UUID(), url: textFile, projectIDs: [], targetID: document.id) { _ in }
        await release.signal()
        #expect(try await lateDocument.value == false)
        #expect(try await store.embeddingRevision(for: docKey) == document.currentVersion.id.uuidString)
        let currentDoc = try #require(try await store.claimEmbeddingJob())
        #expect(try await store.publishEmbeddingVectors(compute(currentDoc, encoder: encoder), lease: currentDoc))

        let meetingKey = EmbeddingSourceKey(kind: .meeting, externalID: "synthetic-meeting")
        try await store.requestEmbeddingReindex(meetingKey)
        let meetingLease = try #require(try await store.claimEmbeddingJob())
        let meetingReached = NativeIndexSignal(), meetingRelease = NativeIndexSignal()
        let lateMeeting = Task {
            do {
                let result = try await compute(meetingLease, encoder: encoder) {
                    await meetingReached.signal(); await meetingRelease.wait()
                }
                return try await store.publishEmbeddingVectors(result, lease: meetingLease)
            } catch { await meetingReached.signal(); throw error }
        }
        await meetingReached.wait()
        try transcript("Борис перенёс запуск на январь.").write(to: transcriptFile, options: .atomic)
        #expect(try await reader.synchronize(meetingID: "synthetic-meeting", store: store))
        try transcriptA.write(to: transcriptFile, options: .atomic)
        #expect(try await reader.synchronize(meetingID: "synthetic-meeting", store: store))
        await meetingRelease.signal()
        #expect(try await lateMeeting.value == false)
        #expect(try Data(contentsOf: transcriptFile) == transcriptA)
        #expect(try Data(contentsOf: textFile) == originalText)
        #expect(try Data(contentsOf: pdf) == originalPDF)
        #expect(try FileManager.default.contentsOfDirectory(atPath: meeting.path) == ["transcript.json"])
    }

    private func compute(_ lease: EmbeddingIndexLease, encoder: E5TextEmbedding,
                         afterFirst: (@Sendable () async -> Void)? = nil) async throws -> [IndexedChunkVectors] {
        var result: [IndexedChunkVectors] = []
        for (index, chunk) in lease.snapshot.chunks.enumerated() {
            let windows = try await encoder.passageWindows(chunk.text)
            let last = try #require(windows.last)
            result.append(.init(chunkID: chunk.id, bodyTokenCount: last.tokenStart + last.tokenCount, windows: windows))
            if index == 0 { await afterFirst?() }
        }
        return result
    }

    private func transcript(_ text: String) throws -> Data {
        try JSONEncoder().encode(Transcript(meetingId: "synthetic-meeting", asrModel: "synthetic-no-audio",
            segments: [.init(start: 12.5, end: 23.75, speaker: .participants, text: text)]))
    }

    private func makePDF(_ url: URL) throws {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 800, height: 220)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Проект Альфа: запуск согласован на декабрь." as NSString).draw(at: CGPoint(x: 25, y: 110), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: url)
    }
}
