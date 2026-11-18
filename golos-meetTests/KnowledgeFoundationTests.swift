import Foundation
import Testing
@testable import golos_meet

@Suite struct KnowledgeFoundationTests {
    @Test func cloudAccessIsExplicitAndSharedSourcesObeyAllOwners() {
        let local = KnowledgeProject(name: "Закрытый проект")
        let ask = KnowledgeProject(name: "С подтверждением", cloudPolicy: .askEveryTime)
        let allowed = KnowledgeProject(name: "Открытый", cloudPolicy: .allowSelectedContext)
        #expect(local.cloudPolicy == .localOnly)
        #expect(!KnowledgeEgress.permitsGeneration(ownerProjectIDs: [local.id], projects: [local],
                                                  approvedProjectIDs: [local.id]))
        #expect(!KnowledgeEgress.permitsGeneration(ownerProjectIDs: [ask.id], projects: [ask]))
        #expect(KnowledgeEgress.permitsGeneration(ownerProjectIDs: [ask.id], projects: [ask],
                                                 approvedProjectIDs: [ask.id]))
        #expect(KnowledgeEgress.permitsGeneration(ownerProjectIDs: [allowed.id], projects: [allowed]))
        #expect(!KnowledgeEgress.permitsGeneration(ownerProjectIDs: [allowed.id, local.id],
                                                  projects: [allowed, local]))
        #expect(!KnowledgeEgress.permitsGeneration(ownerProjectIDs: [UUID()], projects: [allowed]))
        #expect(!KnowledgeEgress.permitsGeneration(ownerProjectIDs: [], projects: [allowed]))
    }

    @Test func chunksPreservePagesAndHaveStableRevisionDependentIDs() {
        let id = UUID()
        let document = ExtractedDocument(title: "Документ", contentHash: "revision1", blocks: [
            .init(text: String(repeating: "Проект проверяет расчёты. ", count: 30), location: .init(page: 1)),
            .init(text: "На второй странице принято решение.", location: .init(page: 2)),
        ])
        let chunks = KnowledgeChunker.chunks(from: document, sourceID: id, maxCharacters: 100, overlap: 20)
        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { $0.text.count <= 100 && !$0.text.isEmpty })
        #expect(chunks.last?.location.page == 2)
        #expect(chunks.dropLast().allSatisfy { $0.location.page == 1 })
        #expect(chunks == KnowledgeChunker.chunks(from: document, sourceID: id, maxCharacters: 100, overlap: 20))
        #expect(Set(chunks.map(\.id)).count == chunks.count)
        let changed = ExtractedDocument(title: document.title, contentHash: "revision2", blocks: document.blocks)
        #expect(chunks.first?.id != KnowledgeChunker.chunks(from: changed, sourceID: id).first?.id)
    }

    @Test func chunkingDoesNotLoseUnbrokenTextOrSplitUnicodeCharacters() {
        let text = String(repeating: "👨‍👩‍👧‍👦ё漢", count: 60)
        let doc = ExtractedDocument(title: "x", contentHash: "hash", blocks: [.init(text: text)])
        let chunks = KnowledgeChunker.chunks(from: doc, sourceID: UUID(), maxCharacters: 15, overlap: 0)
        #expect(chunks.map(\.text).joined() == text)
        #expect(chunks.allSatisfy { $0.text.count <= 15 })
    }

    @Test func unbrokenTextWithOverlapAlwaysAdvances() {
        let doc = ExtractedDocument(title: "x", contentHash: "hash", blocks: [.init(text: String(repeating: "a", count: 25))])
        let chunks = KnowledgeChunker.chunks(from: doc, sourceID: UUID(), maxCharacters: 10, overlap: 9)
        #expect(chunks.count == 16)
        #expect(chunks.last?.text.count == 10)
    }

    @Test func vectorsAreNormalizedAndIncompatibleIndicesAreRejected() throws {
        let a = try KnowledgeVector(modelID: "e5@v1", values: [3, 4])
        let same = try KnowledgeVector(modelID: "e5@v1", values: [6, 8])
        #expect(abs(try a.cosineSimilarity(to: same) - 1) < 0.00001)
        #expect(throws: KnowledgeVectorError.incompatibleModels) {
            try a.cosineSimilarity(to: KnowledgeVector(modelID: "other", values: [3, 4]))
        }
        #expect(throws: KnowledgeVectorError.incompatibleDimensions) {
            try a.cosineSimilarity(to: KnowledgeVector(modelID: "e5@v1", values: [1, 2, 3]))
        }
        #expect(throws: KnowledgeVectorError.invalidVector) { try KnowledgeVector(modelID: "e5", values: [0, 0]) }
        #expect(throws: KnowledgeVectorError.invalidVector) { try KnowledgeVector(modelID: "e5", values: [.nan]) }
        let encoded = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(KnowledgeVector.self, from: encoded)
        #expect(abs(try a.cosineSimilarity(to: decoded) - 1) < 0.00001)
    }
}
