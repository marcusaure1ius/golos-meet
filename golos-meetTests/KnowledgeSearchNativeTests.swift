import Foundation
import AppKit
import PDFKit
import Testing
@testable import golos_meet

@MainActor @Suite(.serialized) struct KnowledgeSearchNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLOS_MEET_E5_FOLDER"] != nil))
    func nativeProjectImportFindPageAndReplicaThenRejectUpdatedSources() async throws {
        let weights = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GOLOS_MEET_E5_FOLDER"]))
        try await EmbeddingModelInstaller(root: weights).verifyFolder(weights)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-hybrid-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let meetings = root.appendingPathComponent("meetings"), documents = root.appendingPathComponent("copies")
        let importer = DocumentImporter(store: store, root: documents)
        let project = try await store.createProject(name: "Север"), other = try await store.createProject(name: "Лира")
        let pdf = root.appendingPathComponent("План запуска.pdf")
        try makePDF(["Общие сведения о проекте Север", "Команда перенесла релиз на 26 ноября.", "Перед запуском нужна проверка нагрузки."]).write(to: pdf)
        let imported = try await importer.importFile(id: UUID(), url: pdf, projectIDs: [project.id]) { _ in }
        let folder = meetings.appendingPathComponent("synthetic")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("transcript.json")
        func writeTranscript(start: Double) throws {
            try JSONSerialization.data(withJSONObject: ["meetingId": "synthetic", "segments": [["start": start, "end": start + 13, "text": "Пилот Север перенесён на конец ноября."]]])
                .write(to: transcript, options: .atomic)
        }
        try writeTranscript(start: 42.5)
        try await store.assignMeeting("synthetic", to: [project.id, other.id])
        let runtime = LocalIndexingService(store: store, meetingsRoot: meetings, inspect: {
            .init(model: .e5Small, folder: weights, load: { try await E5TextEmbedding(folder: weights) })
        })
        await runtime.start(); await runtime.waitUntilIdle()
        let search = KnowledgeSearchService(store: store, meetingsRoot: meetings, documentsRoot: documents,
            prepare: { try await runtime.synchronizeForSearch() }, queryEmbedding: { try await runtime.embedQuery($0) },
            sourceChanged: { await runtime.changed(source: $0) })
        do {
            let found = try await search.search("На какую дату перенесли релиз?", scope: .project(project.id))
            let page = try #require(found.hits.first { $0.source.key.externalID == imported.documentID.uuidString && $0.chunk.location.page == 2 })
            let opened = try await search.open(page)
            let data = try #require(opened.pdf), document = try #require(PDFDocument(data: data))
            #expect(document.pageCount == 3 && document.page(at: 1)?.string?.contains("26 ноября") == true)
            // Actual offline E5 + SQLite + service + page snapshot. Only the
            // generative response is synthetic; this is not a live LLM check.
            try await store.setCloudPolicy(.allowSelectedContext, for: project.id)
            try await store.setCloudPolicy(.allowSelectedContext, for: other.id)
            let questions = KnowledgeQuestionService(store: store, search: search, meetingsRoot: meetings,
                documentsRoot: documents, client: NativeSearchPageCompleter(), model: "synthetic-only")
            let request = try await questions.prepare(question: "На какую дату перенесли релиз?", projectID: project.id)
            let result = try await questions.answer(request)
            let citation = try #require(result.answer.citations.first)
            #expect(citation.location.page == 2 && citation.sourceID == page.chunk.sourceID)
            let answerPage = try await questions.openCitation(citation.label, in: result)
            #expect(PDFDocument(data: try #require(answerPage.pdf))?.page(at: 1)?.string?.contains("26 ноября") == true)
            questions.cancel()
            #expect(try await search.search("релиз", scope: .project(other.id)).hits.allSatisfy { $0.source.key.externalID != imported.documentID.uuidString })
            let meeting = try #require(try await search.search("Пилот Север", scope: .project(project.id)).hits.first { $0.source.key.kind == .meeting })
            #expect(try await search.open(meeting).hit.chunk.location.startSeconds == 42.5)
            try writeTranscript(start: 75)
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(meeting) }
            let fresh = try #require(try await search.search("Пилот Север", scope: .project(project.id)).hits.first { $0.source.key.kind == .meeting })
            #expect(try await search.open(fresh).hit.chunk.location.startSeconds == 75)
            let update = root.appendingPathComponent("План запуска.txt")
            try Data("Релиз перенесён на декабрь.".utf8).write(to: update)
            _ = try await importer.importFile(id: UUID(), url: update, projectIDs: [], targetID: imported.documentID) { _ in }
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(page) }
            let current = try #require(try await search.search("Релиз декабрь", scope: .project(project.id)).hits.first { $0.source.key.kind == .document })
            #expect(try await search.open(current).pdf == nil)
            try await store.assignMeeting("synthetic", to: [])
            await #expect(throws: KnowledgeSearchError.sourceChanged) { try await search.open(fresh) }
            #expect(try await search.search("Пилот Север", scope: .inbox).hits.contains { $0.source.key.kind == .meeting })
        } catch { await runtime.stop(); throw error }
        await runtime.stop()
        #expect(PDFDocument(url: pdf)?.pageCount == 3)
    }

    private func makePDF(_ pages: [String]) throws -> Data {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 40, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

/// A deterministic response over the actual selected input; never calls cloud.
private nonisolated struct NativeSearchPageCompleter: ChatCompleter {
    func complete(model: String, messages: [ChatMessage], responseFormat: ResponseFormat?) async throws -> String {
        guard let input = messages.last?.content,
              let payload = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
              let fragments = payload["fragments"] as? [[String: Any]],
              let page = fragments.first(where: { ($0["location"] as? [String: Any])?["page"] as? Int == 2 }),
              let label = page["label"] as? String else { throw KnowledgeAnswerError.noContext }
        return String(decoding: try JSONSerialization.data(withJSONObject: [
            "answer": "Релиз перенесён на 26 ноября [\(label)].", "sources": [label], "insufficientEvidence": false
        ]), as: UTF8.self)
    }
}
