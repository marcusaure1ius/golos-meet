import Foundation
import CryptoKit

nonisolated enum KnowledgeChunker {
    /// Character bounds, not token bounds. The embedding adapter must additionally
    /// enforce its tokenizer's limit. Blocks never cross page/paragraph boundaries.
    static func chunks(from document: ExtractedDocument, sourceID: UUID,
                       maxCharacters: Int = 1200, overlap: Int = 160) -> [KnowledgeChunk] {
        precondition(maxCharacters > 0 && overlap >= 0 && overlap < maxCharacters)
        var result: [KnowledgeChunk] = []
        for (blockIndex, block) in document.blocks.enumerated() {
            let characters = Array(block.text)
            var start = 0
            while start < characters.count {
                var end = min(start + maxCharacters, characters.count)
                // Prefer a word boundary while keeping enough room to advance
                // beyond the overlap even for long words and unbroken OCR text.
                if end < characters.count {
                    let lower = start + max(overlap + 1, maxCharacters / 2)
                    if lower < end,
                       let boundary = (lower..<end).reversed().first(where: { characters[$0].isWhitespace }) {
                        end = boundary
                    }
                }
                let text = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let key = "\(sourceID.uuidString)|\(document.contentHash)|\(blockIndex)|\(start)|\(end)"
                    let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                    result.append(KnowledgeChunk(id: id, sourceID: sourceID, revision: document.contentHash,
                                                 ordinal: result.count, text: text, location: block.location))
                }
                if end == characters.count { break }
                start = end - overlap
            }
        }
        return result
    }
}
