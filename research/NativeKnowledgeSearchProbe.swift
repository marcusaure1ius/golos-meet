// Actual production FTS5/E5/search/validation; explicit public weights and
// versioned synthetic corpus. No App, Keychain, recording or network client.
import Foundation
import CryptoKit
import Darwin

private nonisolated struct SearchCorpus: Decodable {
    struct Passage: Decodable { let id: String; let topic: String; let text: String }
    struct Query: Decodable { let id: String; let text: String; let relevant_ids: [String] }
    let synthetic_only: Bool
    let passages: [Passage]
    let queries: [Query]
}
private enum SearchProbeError: Error { case invariant(String) }
private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw SearchProbeError.invariant(message) }
}

@main struct NativeKnowledgeSearchProbe {
    private static func median(_ sortedValues: [Double]) throws -> Double {
        try require(!sortedValues.isEmpty, "Median requires a nonempty sample")
        let middle = sortedValues.count / 2
        return sortedValues.count.isMultiple(of: 2)
            ? (sortedValues[middle - 1] + sortedValues[middle]) / 2
            : sortedValues[middle]
    }

    /// Exercises the production report calculation without loading a model.
    private static func checkStatistics(_ reportURL: URL) throws {
        for (sample, expected) in [([3.0], 3.0), ([9.0, 1.0, 3.0], 3.0),
                                   ([9.0, 1.0, 3.0, 5.0], 4.0), ([2.0, 8.0], 5.0)] {
            try require(try median(sample.sorted()) == expected, "Odd/even median self-check failed")
        }
        guard let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any],
              let samples = report["query_ms_including_reconcile_and_freshness"] as? [Double],
              let stored = report["query_median_ms"] as? Double else { throw SearchProbeError.invariant("Missing statistics") }
        let computed = try median(samples.sorted())
        try require(abs(computed - stored) < 1e-9, "Stored median differs from raw measurements")
        print("Median checks passed: odd/even samples; \(samples.count) saved timings → \(computed) ms.")
    }

    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-statistics" {
            try checkStatistics(URL(fileURLWithPath: CommandLine.arguments[2])); return
        }
        guard CommandLine.arguments.count == 4 else {
            fputs("Usage: native-search-probe MODEL_FOLDER SYNTHETIC_CORPUS_JSON REPORT_JSON\n       native-search-probe --check-statistics REPORT_JSON\n", stderr); exit(2)
        }
        let weights = URL(fileURLWithPath: CommandLine.arguments[1])
        try await EmbeddingModelInstaller(root: weights).verifyFolder(weights)
        let corpusBytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let corpus = try JSONDecoder().decode(SearchCorpus.self, from: corpusBytes)
        try require(corpus.synthetic_only && corpus.passages.count == 48 && corpus.queries.count == 20, "Unexpected corpus")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-search-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("knowledge.sqlite")
        let store = ProjectStore(url: database), documents = root.appendingPathComponent("copies"), meetings = root.appendingPathComponent("meetings")
        let importer = DocumentImporter(store: store, root: documents)
        var projects: [String: UUID] = [:], ids: [String: String] = [:]
        for passage in corpus.passages {
            if projects[passage.topic] == nil { projects[passage.topic] = try await store.createProject(name: passage.topic).id }
        }
        for (offset, passage) in corpus.passages.enumerated() {
            let projectID = projects[passage.topic]!
            if offset % 2 == 0 {
                let file = root.appendingPathComponent(passage.id + ".txt")
                try Data(passage.text.utf8).write(to: file)
                let imported = try await importer.importFile(id: UUID(), url: file, projectIDs: [projectID]) { _ in }
                ids[EmbeddingSourceKey(kind: .document, externalID: imported.documentID.uuidString).rawValue] = passage.id
            } else {
                let folder = meetings.appendingPathComponent(passage.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["meetingId": passage.id, "segments": [["start": Double(offset * 10), "end": Double(offset * 10 + 8), "text": passage.text]]])
                    .write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
                try await store.assignMeeting(passage.id, to: [projectID])
                ids[EmbeddingSourceKey(kind: .meeting, externalID: passage.id).rawValue] = passage.id
            }
        }
        let runtime = LocalIndexingService(store: store, meetingsRoot: meetings, inspect: {
            .init(model: .e5Small, folder: weights, load: { try await E5TextEmbedding(folder: weights) })
        })
        let indexStart = ProcessInfo.processInfo.systemUptime
        await runtime.start(); await runtime.waitUntilIdle()
        let indexSeconds = ProcessInfo.processInfo.systemUptime - indexStart
        let jobs = try await store.embeddingJobs()
        try require(jobs.count == 48 && jobs.allSatisfy { $0.state == .ready }, "Incomplete native index")
        let search = KnowledgeSearchService(store: store, meetingsRoot: meetings, documentsRoot: documents,
            prepare: { try await runtime.synchronizeForSearch() }, queryEmbedding: { try await runtime.embedQuery($0) },
            sourceChanged: { await runtime.changed(source: $0) })
        var times: [Double] = [], evidence: [[String: Any]] = [], top1 = 0, recall = 0.0
        for query in corpus.queries {
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await search.search(query.text, scope: .all)
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let returned = result.hits.compactMap { ids[$0.source.key.rawValue] }
            let relevant = Set(query.relevant_ids)
            let found = Set(returned.prefix(5)).intersection(relevant).count
            let value = Double(found) / Double(relevant.count)
            recall += value
            if let first = returned.first, relevant.contains(first) { top1 += 1 }
            if let hit = result.hits.first { _ = try await search.open(hit) }
            evidence.append(["query_id": query.id, "top5": Array(returned.prefix(5)), "relevant_ids": query.relevant_ids, "recall_at_5": value])
            try require(!result.limited && result.semanticMessage == nil, "Unexpected fallback")
        }
        let scoped = try await search.search(corpus.queries[0].text, scope: .project(projects["sever"]!))
        try require(!scoped.hits.isEmpty && scoped.hits.allSatisfy { $0.source.owners == [projects["sever"]!] }, "Scope leak")
        let original = try await search.search("Север", scope: .all)
        let meeting = original.hits.first { $0.source.key.kind == .meeting }!
        let file = meetings.appendingPathComponent(meeting.source.key.externalID).appendingPathComponent("transcript.json")
        let bytes = try Data(contentsOf: file)
        try Data("{broken".utf8).write(to: file, options: .atomic)
        try bytes.write(to: file, options: .atomic)
        do { _ = try await search.open(meeting); throw SearchProbeError.invariant("Accepted file ABA") }
        catch KnowledgeSearchError.sourceChanged {}
        let values = times.sorted()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = [
            "synthetic_only": true, "model_id": EmbeddingIndexModel.e5Small.id,
            "corpus_sha256": SHA256.hash(data: corpusBytes).map { String(format: "%02x", $0) }.joined(),
            "sources": jobs.count, "documents": 24, "meetings": 24, "queries": corpus.queries.count,
            "index_with_cold_runtime_seconds": indexSeconds, "sources_per_second_including_cold_start": 48 / indexSeconds,
            "query_ms_including_reconcile_and_freshness": times, "query_median_ms": try median(values),
            "query_p95_ms": values[min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)],
            "top1_hits": top1, "recall_at_5_macro": recall / Double(corpus.queries.count),
            "peak_cli_rss_bytes": usage.ru_maxrss,
            "sqlite_bytes": (try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? NSNumber)?.int64Value ?? 0,
            "filesystem_aba_rejected": true, "project_scope_checked": true, "ranking": "FTS5 BM25 + max-window cosine >= 0.70, RRF k=60; semantic weight 2 for >=4 words, otherwise 1; max 3/source, 30 hits",
            "results": evidence
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
        await runtime.stop()
        print("Native local hybrid search passed: 48 synthetic sources, 20 Russian queries, scope/open/ABA checks.")
    }
}
