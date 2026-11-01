import Foundation
import CryptoKit
import Testing
@testable import golos_meet

@MainActor @Suite struct MemoryQueueMigrationTests {
    private var fixture: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("research/memory-queue-37/v7-fixture")
    }
    private func copyFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-v7-migration-\(UUID())")
        try FileManager.default.copyItem(at:fixture,to:root)
        return root
    }
    private func objects(_ db:ProjectDatabase) throws -> [[String]] {
        try db.rows("SELECT type,name,COALESCE(sql,'') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name")
    }
    private func contents(_ db:ProjectDatabase, tables:[String]) throws -> [String:[[String]]] {
        var result:[String:[[String]]] = [:]
        func quoted(_ name:String) -> String { "\"" + name.replacingOccurrences(of:"\"",with:"\"\"") + "\"" }
        for table in tables {
            let columns = try db.rows("PRAGMA table_info(\(quoted(table)))").map { "quote(\(quoted($0[1])))" }.joined(separator:",")
            result[table] = try db.rows("SELECT \(columns) FROM \(quoted(table))").sorted { $0.joined(separator:"|") < $1.joined(separator:"|") }
        }
        return result
    }
    private func originalFiles(_ root:URL) throws -> [String:Data] {
        let files = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])!
        var result:[String:Data] = [:]
        for case let file as URL in files where !file.lastPathComponent.hasPrefix("knowledge.sqlite") {
            if try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(root.path.count+1))] = try Data(contentsOf:file)
            }
        }
        return result
    }
    @Test func genuineAcceptedV7MigratesWithEveryMemoryTableVectorFTSAssignmentAndOriginalPreserved() async throws {
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.deletingLastPathComponent().appendingPathComponent("v7-manifest.json"))) as? [String:Any])
        #expect(manifest["actual_previous_schema"] as? Int == 7 && manifest["downgraded_new_schema"] as? Bool == false)
        #expect(manifest["accepted_ref"] as? String == "b118fccda792bd3fcef7f2169e103cdcaa77d909")
        let hashes = try #require(manifest["files"] as? [String:String])
        for (path, expected) in hashes {
            let hash = SHA256.hash(data: try Data(contentsOf: fixture.appendingPathComponent(path))).map { String(format:"%02x",$0) }.joined()
            #expect(hash == expected)
        }
        let root = try copyFixture(); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("knowledge.sqlite"), before = try ProjectDatabase(url:url)
        #expect(try before.rows("PRAGMA user_version") == [["7"]])
        #expect(try before.rows("SELECT name FROM sqlite_master WHERE name LIKE 'memory_queue_%'").isEmpty)
        let schema = try objects(before), tables = schema.filter { $0[0] == "table" }.map { $0[1] }
        let values = try contents(before,tables:tables), files = try originalFiles(root)
        #expect(values["document_versions"]?.count == 2 && values["memory_events"]?.count == 2)
        #expect(values["memory_links"]?.isEmpty == false && values["memory_head_versions"]?.count == 2)
        #expect(values["embedding_vectors"]?.isEmpty == false && values["knowledge_fts"]?.isEmpty == false)
        #expect(values["assignment_work"]?.isEmpty == false)
        let store = ProjectStore(url:url); _ = try await store.snapshot()
        #expect(try before.rows("PRAGMA user_version") == [["8"]])
        #expect(try contents(before,tables:tables) == values)
        #expect(try originalFiles(root) == files)
        let afterSchema = try objects(before)
        #expect(schema.allSatisfy { afterSchema.contains($0) })
        #expect(try before.rows("SELECT origin FROM meeting_decisions WHERE meeting_id='manual-inbox'") == [["manual"]])
        #expect(try before.rows("SELECT state FROM assignment_work WHERE meeting_id='fixture-meeting'") == [["pending"]])
        #expect(try await store.memoryQueueSnapshot().jobs.isEmpty)
        #expect(try await store.knowledgeLexicalSearch(expression:"\"релиз\"*",scope:.all).isEmpty == false)
        #expect(try before.rows("PRAGMA foreign_key_check").isEmpty)
        let restarted = ProjectStore(url:url); _ = try await restarted.snapshot()
        #expect(try contents(before,tables:tables) == values)
    }

    @Test func midDDLQueueFailureRollsBackVersionSchemaAndEveryLegacyValueThenRetries() async throws {
        let root = try copyFixture(); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("knowledge.sqlite"), before = try ProjectDatabase(url:url)
        try before.execute("CREATE TABLE memory_queue_batches (sentinel TEXT)")
        try before.execute("INSERT INTO memory_queue_batches VALUES ('keep-original')")
        let schema = try objects(before), tables = schema.filter { $0[0] == "table" }.map { $0[1] }
        let values = try contents(before,tables:tables), files = try originalFiles(root)
        await #expect(throws:ProjectStoreError.self) { try await ProjectStore(url:url).snapshot() }
        #expect(try before.rows("PRAGMA user_version") == [["7"]])
        #expect(try objects(before) == schema)
        #expect(try contents(before,tables:tables) == values)
        #expect(try originalFiles(root) == files)
        #expect(try before.rows("SELECT name FROM sqlite_master WHERE name IN ('memory_queue_runtime','memory_queue_work')").isEmpty)
        try before.execute("DROP TABLE memory_queue_batches")
        _ = try await ProjectStore(url:url).snapshot()
        #expect(try before.rows("PRAGMA user_version") == [["8"]])
        #expect(try contents(before,tables:tables.filter { $0 != "memory_queue_batches" }) == values.filter { $0.key != "memory_queue_batches" })
        #expect(try originalFiles(root) == files)
    }
}
