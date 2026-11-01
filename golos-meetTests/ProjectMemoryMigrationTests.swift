import Foundation
import CryptoKit
import Testing
@testable import golos_meet

@MainActor @Suite struct ProjectMemoryMigrationTests {
    private var fixture: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("research/memory-history-36/v6-fixture")
    }
    private func copyFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-v6-migration-\(UUID())")
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
    @Test func genuinePreviousSchemaPreservesEveryLegacyTableBlobOriginalAndManualInbox() async throws {
        let manifestURL = fixture.deletingLastPathComponent().appendingPathComponent("v6-manifest.json")
        let manifest = try #require(try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
        #expect(manifest["actual_previous_schema"] as? Int == 6 && manifest["downgraded_new_schema"] as? Bool == false)
        #expect(manifest["accepted_ref"] as? String == "8efd4be56d77a34184e4955f54373bac2f7a8f64")
        let hashes = try #require(manifest["files"] as? [String:String])
        for (file, expected) in hashes {
            let hash = SHA256.hash(data:try Data(contentsOf:fixture.appendingPathComponent(file))).map { String(format:"%02x",$0) }.joined()
            #expect(hash == expected)
        }
        let root = try copyFixture(); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("knowledge.sqlite"), before = try ProjectDatabase(url:url)
        #expect(try before.rows("PRAGMA user_version") == [["6"]])
        #expect(try before.rows("SELECT name FROM sqlite_master WHERE name LIKE 'memory_%'").isEmpty)
        let schema = try objects(before), tables = schema.filter { $0[0] == "table" }.map { $0[1] }
        let values = try contents(before,tables:tables), files = try originalFiles(root)
        #expect(values["document_versions"]?.count == 2 && values["embedding_vectors"]?.isEmpty == false)
        #expect(values["assignment_work"]?.isEmpty == false && values["knowledge_fts"]?.isEmpty == false)
        let store = ProjectStore(url:url), snapshot = try await store.snapshot()
        let after = try ProjectDatabase(url:url)
        #expect(try after.rows("PRAGMA user_version") == [["7"]])
        #expect(try contents(after,tables:tables) == values)
        #expect(try originalFiles(root) == files)
        let newSchema = try objects(after)
        #expect(schema.allSatisfy { newSchema.contains($0) })
        #expect(snapshot.projects.count == 2 && snapshot.meetingProjects["manual-inbox"] == nil)
        #expect(try after.rows("SELECT origin FROM meeting_decisions WHERE meeting_id='manual-inbox'") == [["manual"]])
        #expect(try after.rows("SELECT state FROM assignment_work WHERE meeting_id='fixture-meeting'") == [["pending"]])
        let hits = try await store.knowledgeLexicalSearch(expression:"\"релиз\"*",scope:.all)
        #expect(!hits.isEmpty && hits.contains { $0.chunk.text.contains("декабрь") })
        let key = try #require(try await store.knowledgeSearchCatalog(scope:.all).sources.first?.key)
        #expect(try await store.embeddingWindows(for:key,model:.init(id:"synthetic-migration-only",dimensions:2)).isEmpty == false)
        #expect(try after.rows("PRAGMA foreign_key_check").isEmpty)
        let restarted = ProjectStore(url:url)
        #expect(try await restarted.snapshot() == snapshot)
    }

    @Test func failureAfterSeveralNewDDLsRollsBackVersionObjectsAndAllLegacyData() async throws {
        let root = try copyFixture(); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("knowledge.sqlite"), before = try ProjectDatabase(url:url)
        // Real mid-DDL failure: memory_state/events/indexes have already been
        // created in the transaction when CREATE memory_links collides.
        try before.execute("CREATE TABLE memory_links (sentinel TEXT)")
        try before.execute("INSERT INTO memory_links VALUES ('keep-original')")
        let schema = try objects(before), tables = schema.filter { $0[0] == "table" }.map { $0[1] }
        let values = try contents(before,tables:tables), files = try originalFiles(root)
        await #expect(throws:ProjectStoreError.self) { try await ProjectStore(url:url).snapshot() }
        let after = try ProjectDatabase(url:url)
        #expect(try after.rows("PRAGMA user_version") == [["6"]])
        #expect(try objects(after) == schema && contents(after,tables:tables) == values)
        #expect(try originalFiles(root) == files)
        #expect(try after.rows("SELECT name FROM sqlite_master WHERE name IN ('memory_state','memory_events','memory_head_versions','memory_batches')").isEmpty)
        #expect(try after.rows("SELECT sentinel FROM memory_links") == [["keep-original"]])
        try after.execute("DROP TABLE memory_links")
        _ = try await ProjectStore(url:url).snapshot()
        #expect(try after.rows("PRAGMA user_version") == [["7"]])
        #expect(try contents(after,tables:tables.filter { $0 != "memory_links" }) == values.filter { $0.key != "memory_links" })
    }
}
