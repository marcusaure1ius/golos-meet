import Foundation
import CryptoKit
import Darwin

@main struct NativeMeetingAssignmentProbe {
    struct Corpus: Decodable {
        struct Project: Decodable { let key: String; let name: String; let text: String; let manualMeeting: Bool }
        struct Sample: Decodable { let id: String; let partition: String; let texts: [String]; let expected: [String] }
        let projects: [Project]; let cases: [Sample]
    }
    static func main() async throws {
        guard [5, 6].contains(CommandLine.arguments.count) else {
            fputs("Usage: probe MODEL_FOLDER CORPUS_JSON PARTITION REPORT_JSON [--runtime]\n", stderr); exit(2)
        }
        let useWorker = CommandLine.arguments.last == "--runtime"
        let weights = URL(fileURLWithPath: CommandLine.arguments[1])
        try await EmbeddingModelInstaller(root: weights).verifyFolder(weights)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let corpus = try JSONDecoder().decode(Corpus.self, from: bytes)
        let partition = CommandLine.arguments[3]
        guard ["calibration", "regression", "evaluation"].contains(partition) else { exit(2) }
        let samples = corpus.cases.filter { $0.partition == partition }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-assignment-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let meetings = root.appendingPathComponent("meetings"), copies = root.appendingPathComponent("copies")
        let importer = DocumentImporter(store: store, root: copies)
        var projects: [String: UUID] = [:]
        func writeMeeting(_ id: String, _ texts: [String]) throws {
            let folder = meetings.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let segments = texts.enumerated().map { ["start": Double($0.offset * 30), "end": Double($0.offset * 30 + 20), "text": $0.element] as [String: Any] }
            try JSONSerialization.data(withJSONObject: ["meetingId": id, "segments": segments])
                .write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        }
        for project in corpus.projects {
            let p = try await store.createProject(name: project.name); projects[project.key] = p.id
            if project.manualMeeting {
                try writeMeeting("context-\(project.key)", [project.text])
                try await store.assignMeeting("context-\(project.key)", to: [p.id])
            } else {
                let file = root.appendingPathComponent("\(project.key).txt")
                try Data(project.text.utf8).write(to: file)
                _ = try await importer.importFile(id: UUID(), url: file, projectIDs: [p.id]) { _ in }
            }
        }
        for sample in samples { try writeMeeting(sample.id, sample.texts) }
        let runtime = LocalIndexingService(store: store, meetingsRoot: meetings, inspect: {
            .init(model: .e5Small, folder: weights, load: { try await E5TextEmbedding(folder: weights) })
        })
        let indexStart = ProcessInfo.processInfo.systemUptime
        await runtime.start(); await runtime.waitUntilIdle()
        let indexSeconds = ProcessInfo.processInfo.systemUptime - indexStart
        guard try await store.embeddingJobs().allSatisfy({ $0.state == .ready }) else { throw MeetingAssignmentError.notReady }
        let service = MeetingAssignmentService(store: store, meetingsRoot: meetings, documentsRoot: copies)
        let worker = MeetingAssignmentWorker(store: store, meetingsRoot: meetings, documentsRoot: copies, indexAvailable: true)
        let evidenceReader = MeetingAssignmentEvidenceReader(store: store, meetingsRoot: meetings, documentsRoot: copies)
        let drainStart = ProcessInfo.processInfo.systemUptime
        if useWorker { await worker.start(); await worker.waitUntilIdle() }
        let drainSeconds = ProcessInfo.processInfo.systemUptime - drainStart
        var staleChecked = false
        if useWorker, let id = samples.first(where: { !$0.expected.isEmpty && $0.id.contains("literal") })?.id ?? samples.first(where: { !$0.expected.isEmpty })?.id,
           let decision = try await store.assignmentRuntimeSnapshot().decisions[id], decision.origin == .automatic,
           let first = decision.result?.evidence.first {
            _ = try await evidenceReader.open(meetingID: id, projectID: first.projectID, context: true)
            try await store.requestEmbeddingReindex(.init(kind: .meeting, externalID: id))
            await worker.changed(); await worker.waitUntilIdle()
            guard try await store.snapshot().meetingProjects[id] == nil,
                  try await store.assignmentRuntimeSnapshot().work[id]?.state == .waiting else { throw MeetingAssignmentError.stale }
            do { _ = try await evidenceReader.open(meetingID: id, projectID: first.projectID, context: false); throw EmbeddingIndexError.invalidSource }
            catch is MeetingAssignmentError { staleChecked = true }
            await runtime.changed(); await runtime.waitUntilIdle()
            await worker.changed(); await worker.waitUntilIdle()
            guard try await store.assignmentRuntimeSnapshot().work[id]?.state == .current else { throw MeetingAssignmentError.stale }
        }
        var rows: [[String: Any]] = [], truePositive = 0, falsePositive = 0, missed = 0
        for sample in samples {
            let start = ProcessInfo.processInfo.systemUptime
            guard let plan = try await service.prepare(meetingID: sample.id) else { throw MeetingAssignmentError.stale }
            let outcome = try await service.commit(plan)
            guard useWorker ? outcome == .unchanged : outcome == .applied else { throw MeetingAssignmentError.stale }
            if useWorker {
                guard let saved = try await store.assignmentRuntimeSnapshot().decisions[sample.id], saved.result == plan.result else { throw MeetingAssignmentError.stale }
                for item in plan.result.evidence {
                    _ = try await evidenceReader.open(meetingID: sample.id, projectID: item.projectID, context: false)
                    _ = try await evidenceReader.open(meetingID: sample.id, projectID: item.projectID, context: true)
                }
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let persisted = try await store.snapshot().meetingProjects[sample.id] ?? []
            guard persisted == plan.result.assignedProjectIDs else { throw MeetingAssignmentError.stale }
            let actual = Set(projects.compactMap { persisted.contains($0.value) ? $0.key : nil })
            let expected = Set(sample.expected)
            truePositive += actual.intersection(expected).count
            falsePositive += actual.subtracting(expected).count
            missed += expected.subtracting(actual).count
            let state = try await store.meetingAssignmentCheckpoint()
            guard let repeatPlan = try await service.prepare(meetingID: sample.id),
                  try await service.commit(repeatPlan) == .unchanged,
                  try await store.meetingAssignmentCheckpoint().epoch == state.epoch else { throw MeetingAssignmentError.stale }
            let scores: [[String: Any]] = plan.result.evidence.map { evidence in
                ["project": projects.first { $0.value == evidence.projectID }!.key,
                 "similarity": evidence.similarity, "explicit_name": evidence.explicitName,
                 "meeting_text": evidence.meetingChunk.text, "context_text": evidence.contextChunk.text,
                 "context_kind": evidence.contextSource.kind.rawValue, "competing_similarity": evidence.competingSimilarity]
            }
            rows.append(["id": sample.id, "expected": sample.expected, "actual": actual.sorted(),
                         "milliseconds": elapsed, "scores": scores, "suggested_topic": plan.result.suggestedTopic as Any? ?? NSNull()])
            // Explicit Inbox on a new connection fences further classification.
            try await store.assignMeeting(sample.id, to: [])
            if useWorker { await worker.changed(); await worker.waitUntilIdle() }
            let reopened = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
            guard try await reopened.meetingAssignmentCheckpoint().decisions[sample.id]?.origin == .manual,
                  try await service.prepare(meetingID: sample.id) == nil else { throw MeetingAssignmentError.stale }
        }
        if useWorker {
            await worker.stop(); await worker.start(); await worker.waitUntilIdle()
            let restarted = try await store.assignmentRuntimeSnapshot()
            guard samples.allSatisfy({ restarted.work[$0.id]?.state == .manual }) else { throw MeetingAssignmentError.stale }
        }
        await worker.stop()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["partition": partition, "algorithm": MeetingAssignmentService.algorithm,
            "corpus_sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "synthetic_only": true, "production_wiring": false, "serial_worker": useWorker, "worker_initial_drain_seconds": drainSeconds, "stale_evidence_reindex_recovery": staleChecked, "timing_scope": useWorker ? "prepare+unchanged commit+evidence opens after automatic drain" : "prepare+commit", "model_id": EmbeddingIndexModel.e5Small.id,
            "auto_threshold": 0.90, "proposal_threshold": 0.90, "required_margin": 0.04, "cold_index_seconds": indexSeconds,
            "peak_cli_rss_bytes": usage.ru_maxrss, "true_positive_links": truePositive,
            "false_positive_links": falsePositive, "missed_links": missed, "cases": rows,
            "idempotence_checked": true, "manual_inbox_restart_checked": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[4]), options: .atomic)
        await runtime.stop()
        print("\(partition): true links \(truePositive), false links \(falsePositive), missed \(missed); \(rows.count) cases")
    }
}
