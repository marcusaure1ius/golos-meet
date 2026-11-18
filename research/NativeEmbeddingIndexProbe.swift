// Developer-only, production core files, synthetic source bytes in a fresh temp
// directory. Does not compile or construct App, AppPaths, Keychain or ASR.
import Foundation

@main struct NativeEmbeddingIndexProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: native-embedding-index-probe MODEL_FOLDER REPORT_JSON\n", stderr)
            exit(2)
        }
        let modelFolder = URL(fileURLWithPath: CommandLine.arguments[1])
        try await EmbeddingModelInstaller(root: modelFolder).verifyFolder(modelFolder)
        let encoder = try await E5TextEmbedding(folder: modelFolder)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("golos-native-index-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("knowledge.sqlite")
        let store = ProjectStore(url: dbURL)
        let file = root.appendingPathComponent("Synthetic.txt")
        try Data(("Запуск согласован на декабрь. " + String(repeating: "漢字🧪 ", count: 450)).utf8).write(to: file)
        let importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
        _ = try await importer.importFile(id: UUID(), url: file, projectIDs: []) { _ in }
        let meetings = root.appendingPathComponent("meetings")
        let meeting = meetings.appendingPathComponent("synthetic")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let transcript: [String: Any] = ["meetingId": "synthetic", "segments": [
            ["start": 12.5, "end": 23.75, "text": "Анна отвечает за запуск проекта в декабре."]
        ]]
        try JSONSerialization.data(withJSONObject: transcript).write(to: meeting.appendingPathComponent("transcript.json"))
        try await MeetingEmbeddingSnapshotReader(root: meetings).synchronize(meetingID: "synthetic", store: store)
        try await store.activateEmbeddingModel(.e5Small)
        var records: [[String: Any]] = []
        while let lease = try await store.claimEmbeddingJob() {
            var result: [IndexedChunkVectors] = []
            for chunk in lease.snapshot.chunks {
                let windows = try await encoder.passageWindows(chunk.text)
                guard let last = windows.last else { throw EmbeddingIndexError.invalidVectors }
                result.append(.init(chunkID: chunk.id, bodyTokenCount: last.tokenStart + last.tokenCount, windows: windows))
            }
            guard try await store.publishEmbeddingVectors(result, lease: lease) else { throw EmbeddingIndexError.invalidSource }
            let persisted = try await ProjectStore(url: dbURL).embeddingWindows(for: lease.job.source, model: .e5Small)
            for window in persisted {
                records.append(["source_kind": window.source.kind.rawValue, "source_key": window.source.rawValue,
                                "source_revision": window.revision, "generation": lease.job.generation,
                                "chunk_id": window.chunk.id, "chunk_source_id": window.chunk.sourceID.uuidString,
                                "chunk_revision": window.chunk.revision, "model_id": window.vector.modelID, "dimensions": window.vector.values.count,
                                "token_start": window.tokenStart, "token_count": window.tokenCount,
                                "start_seconds": window.chunk.location.startSeconds as Any? ?? NSNull(),
                                "end_seconds": window.chunk.location.endSeconds as Any? ?? NSNull()])
            }
        }
        let jobs = try await store.embeddingJobs()
        guard jobs.count == 2, jobs.allSatisfy({ $0.state == .ready }), records.count > 2 else { throw EmbeddingIndexError.corruptIndex }
        let report: [String: Any] = ["sources": jobs.count, "windows": records, "all_ready": true,
                                   "synthetic_temp_only": true, "production_wiring": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print("Native E5 persistence passed: \(jobs.count) sources, \(records.count) windows, reopened SQLite.")
    }
}
