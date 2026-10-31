// Explicit public weights + fresh synthetic temp sources. No App/UI/Keychain/ASR.
import Foundation

private actor LoadCounter {
    private var count = 0
    func loaded() { count += 1 }
    func value() -> Int { count }
}

@main struct NativeIndexingQueueProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: native-indexing-queue-probe MODEL_FOLDER REPORT_JSON\n", stderr)
            exit(2)
        }
        let weights = URL(fileURLWithPath: CommandLine.arguments[1])
        try await EmbeddingModelInstaller(root: weights).verifyFolder(weights)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-queue-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let file = root.appendingPathComponent("План.txt")
        try Data(("Запуск проекта в декабре. " + String(repeating: "漢字🧪 ", count: 450)).utf8).write(to: file)
        _ = try await DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
            .importFile(id: UUID(), url: file, projectIDs: []) { _ in }
        let meetings = root.appendingPathComponent("meetings"), meeting = meetings.appendingPathComponent("synthetic")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let transcript = meeting.appendingPathComponent("transcript.json")
        func write(_ text: String) throws {
            try JSONSerialization.data(withJSONObject: ["meetingId": "synthetic", "segments": [["start": 3, "end": 8, "text": text]]])
                .write(to: transcript, options: .atomic)
        }
        try write("Анна согласовала запуск в декабре.")
        let counter = LoadCounter()
        let service = LocalIndexingService(store: store, meetingsRoot: meetings, inspect: {
            .init(model: .e5Small, folder: weights, load: {
                await counter.loaded()
                return try await E5TextEmbedding(folder: weights)
            })
        })
        await service.start(); await service.start(); await service.waitUntilIdle()
        let before = try await store.embeddingJobs()
        guard before.count == 2, before.allSatisfy({ $0.state == .ready }) else { throw EmbeddingIndexError.invalidVectors }
        let key = EmbeddingSourceKey(kind: .meeting, externalID: "synthetic")
        let old = before.first { $0.source == key }!
        try write("Борис перенёс запуск на январь.")
        // Exercise the production event-routing/reconciliation path. Actual OS
        // delivery is tested separately through KnowledgeFileMonitor in XCTest.
        await service.filesChanged([transcript.path], modelsRoot: root.appendingPathComponent("models"))
        await service.waitUntilIdle()
        let current = try await store.embeddingJobs()
        guard current.first(where: { $0.source == key })?.generation != old.generation,
              current.allSatisfy({ $0.state == .ready }) else { throw EmbeddingIndexError.invalidSource }
        await service.modelChanged(); await service.waitUntilIdle()
        guard try await store.embeddingJobs().map(\.generation) == current.map(\.generation),
              await counter.value() == 1 else { throw EmbeddingIndexError.invalidModel }
        let query = try await service.embedQuery("Когда запускаем проект?")
        let vectors = try await store.embeddingWindows(for: key, model: .e5Small)
        guard query.values.count == 384, vectors.first?.chunk.text.contains("Борис") == true else { throw EmbeddingIndexError.invalidVectors }
        let report: [String: Any] = ["synthetic_temp_only": true, "sources_ready": current.count,
                                   "model_id": query.modelID, "query_dimensions": query.values.count,
                                   "encoder_loads": await counter.value(), "same_id_cache_preserved": true,
                                   "external_reconciliation": true, "process_local_event_delivery_tested_in_xctest": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        await service.stop()
        print("Native utility queue passed: 2 sources, one encoder, source refresh, same-ID cache, 384d query.")
    }
}
