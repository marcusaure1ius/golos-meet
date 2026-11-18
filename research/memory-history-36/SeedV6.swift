import Foundation

/// Compiled ONLY against frozen accepted v6 sources by generate_v6.py.
@main struct SeedV6 {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let p = try await store.createProject(name: "Сохранённый проект"), q = try await store.createProject(name: "Общий владелец", parentID: p.id)
        try await store.setCloudPolicy(.allowSelectedContext, for: p.id)
        try await store.assignMeeting("fixture-meeting", to: [p.id, q.id])
        try await store.assignMeeting("manual-inbox", to: [])
        let importer = DocumentImporter(store: store, root: root.appendingPathComponent("copies"))
        let file = root.appendingPathComponent("original.txt")
        try Data("Исходный срок релиза — ноябрь.".utf8).write(to: file)
        let imported = try await importer.importFile(id: UUID(), url: file, projectIDs: [p.id, q.id]) { _ in }
        try Data("Новая версия: релиз перенесён на декабрь.".utf8).write(to: file)
        _ = try await importer.importFile(id: UUID(), url: file, projectIDs: [], targetID: imported.documentID) { _ in }
        let folder = root.appendingPathComponent("meetings/fixture-meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["meetingId": "fixture-meeting", "segments": [
            ["start": 42.5, "end": 55, "text": "Для запуска нужна проверка нагрузки."]]])
            .write(to: folder.appendingPathComponent("transcript.json"))
        _ = try await MeetingEmbeddingSnapshotReader(root: root.appendingPathComponent("meetings")).synchronize(meetingID: "fixture-meeting", store: store)
        try await store.activateEmbeddingModel(.init(id: "synthetic-migration-only", dimensions: 2))
        while let lease = try await store.claimEmbeddingJob() {
            let vector = try KnowledgeVector(modelID: lease.model.id, values: [1,0])
            let results = lease.snapshot.chunks.map { IndexedChunkVectors(chunkID: $0.id, bodyTokenCount: 1,
                windows: [.init(tokenStart: 0, tokenCount: 1, vector: vector)]) }
            guard try await store.publishEmbeddingVectors(results, lease: lease) else { fatalError("Fixture lease failed") }
        }
        let db = try ProjectDatabase(url: root.appendingPathComponent("knowledge.sqlite"))
        guard try db.rows("PRAGMA user_version") == [["6"]] else { fatalError("Must be genuine previous v6") }
        try db.execute("INSERT INTO assignment_work VALUES ('fixture-meeting','synthetic-pending','seed-generation','pending','')")
        let report: [String: Any] = ["schema":6,"project_id":p.id.uuidString,"shared_owner_id":q.id.uuidString,
            "document_id":imported.documentID.uuidString,"synthetic_vectors":true,"native_embedding_inference":false,
            "model_downloads":false,"cloud":false]
        try JSONSerialization.data(withJSONObject: report, options:[.sortedKeys,.prettyPrinted]).write(to: root.appendingPathComponent("fixture.json"))
    }
}
