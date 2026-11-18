import Foundation
@main struct CapRecovery {
    @MainActor static func main() async throws {
        let original = URL(fileURLWithPath: "/tmp/review50-independent-DC699D20-A70F-4831-B6AD-06C2047EBD0C")
        for mode in ["correction", "retraction"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("golos36-actual-legacy-\(mode)-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("knowledge.sqlite")
            try FileManager.default.copyItem(at: original.appendingPathComponent("knowledge.sqlite"), to: url)
            let db = try ProjectDatabase(url: url), store = ProjectStore(url: url)
            // Only read the original source files so their saved inode/stamp is
            // still truthful. All writes go exclusively to a copied database.
            let service = ProjectMemoryHistoryService(store: store, meetingsRoot: original.appendingPathComponent("meetings"), documentsRoot: original.appendingPathComponent("copies"))
            let rows = try db.rows("SELECT e.id FROM memory_events e WHERE json_extract(e.body,'$.statement.subject')='fanout-limit' AND NOT EXISTS (SELECT 1 FROM memory_links l WHERE l.target_id=e.id AND l.kind IN ('replaces','retracts','corrects')) ORDER BY e.sequence")
            precondition(rows.count == 257)
            let target = UUID(uuidString: rows.last![0])!, other = UUID(uuidString: rows.first![0])!
            let event = try await store.memoryEvent(target)
            let lease = try await service.beginCorrection(eventID: target, intentID: UUID())
            var draft = MemoryDraft(statement: event.statement, evidenceChunkIDs: Set(event.evidenceChunkIDs))
            do { _ = try await service.publish([draft], lease: lease); fatalError("Single replacement must not keep 257 assertions") }
            catch ProjectMemoryError.limited {}
            if mode == "correction" { draft.links = [.init(targetID: other, kind: .replaces)] }
            else { draft.action = .retraction; draft.links = [.init(targetID: target, kind: .retracts)] }
            let result = try await service.publish([draft], lease: lease).eventIDs[0]
            let active = try db.rows("SELECT COUNT(*) FROM memory_events e WHERE json_extract(e.body,'$.statement.subject')='fanout-limit' AND json_extract(e.body,'$.action')='assertion' AND NOT EXISTS (SELECT 1 FROM memory_links l WHERE l.target_id=e.id AND l.kind IN ('replaces','retracts','corrects'))")
            precondition(active == [["256"]])
            let head = try await service.heads(projectID: event.projectID).heads.first { $0.entry.event.id == result }!
            precondition(head.manualSelection && head.usableAsCurrent == (mode == "correction"))
            let retained = try await store.memoryEvent(target)
            precondition(retained.id == target)
            let violations = try db.rows("PRAGMA foreign_key_check")
            precondition(violations.isEmpty)
            print("PASS actual previous-API 257 recovery: \(mode), active assertions=256, original history retained, manual head valid, FK clean. Copy: \(root.path)")
        }
    }
}
