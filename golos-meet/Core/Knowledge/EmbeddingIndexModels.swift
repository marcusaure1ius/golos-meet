import Foundation
import CryptoKit

nonisolated enum EmbeddingSourceKind: String, Codable, Sendable { case document, meeting }

nonisolated struct EmbeddingSourceKey: Hashable, Codable, Sendable {
    let kind: EmbeddingSourceKind
    let externalID: String
    var rawValue: String { "\(kind.rawValue):\(externalID)" }
    var chunkSourceID: UUID {
        if kind == .document, let id = UUID(uuidString: externalID) { return id }
        let bytes = Array(SHA256.hash(data: Data(rawValue.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

nonisolated struct EmbeddingIndexModel: Equatable, Sendable {
    let id: String
    let dimensions: Int
    static let e5Small = EmbeddingIndexModel(id: EmbeddingModelManifest.e5Small.modelID, dimensions: 384)
}

nonisolated struct EmbeddingSourceSnapshot: Sendable, Equatable {
    let key: EmbeddingSourceKey
    /// Document version UUID or meeting transcript fingerprint, not a filename.
    let revision: String
    let chunks: [KnowledgeChunk]
}

nonisolated enum EmbeddingIndexState: String, Sendable {
    case waitingForModel, queued, running, ready, failed, cancelled
}

nonisolated struct EmbeddingIndexJob: Sendable, Equatable {
    let source: EmbeddingSourceKey
    let revision: String
    let generation: String
    let modelID: String
    let state: EmbeddingIndexState
    let completed: Int
    let total: Int
    let message: String
}

nonisolated struct EmbeddingIndexLease: Sendable {
    let job: EmbeddingIndexJob
    let attempt: String
    let model: EmbeddingIndexModel
    let snapshot: EmbeddingSourceSnapshot
}

nonisolated struct IndexedChunkVectors: Sendable {
    let chunkID: String
    let bodyTokenCount: Int
    let windows: [EmbeddedPassageWindow]
}

nonisolated struct StoredEmbeddingWindow: Sendable {
    let source: EmbeddingSourceKey
    let revision: String
    let chunk: KnowledgeChunk
    let tokenStart: Int
    let tokenCount: Int
    let vector: KnowledgeVector
}

nonisolated enum EmbeddingIndexError: Error, LocalizedError, Equatable {
    case invalidSource, invalidModel, invalidVectors, corruptIndex, invalidTranscript
    var errorDescription: String? {
        switch self {
        case .invalidSource: "Источник для индексации отсутствует или повреждён."
        case .invalidModel: "Модель и размерность индекса несовместимы."
        case .invalidVectors: "Модель вернула неполный или некорректный результат. Индекс не изменён."
        case .corruptIndex: "Индекс повреждён. Выполните повторную индексацию источника."
        case .invalidTranscript: "Расшифровка повреждена или не содержит текста для индексации."
        }
    }
}

/// Portable float32 little-endian storage, exactly four bytes per component.
nonisolated enum EmbeddingVectorBytes {
    static func encode(_ vector: KnowledgeVector) -> Data {
        var data = Data(capacity: vector.values.count * 4)
        for value in vector.values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data, model: EmbeddingIndexModel) throws -> KnowledgeVector {
        guard (1...4096).contains(model.dimensions), data.count == model.dimensions * 4 else { throw EmbeddingIndexError.corruptIndex }
        let bytes = Array(data)
        let values = stride(from: 0, to: bytes.count, by: 4).map { i in
            Float(bitPattern: UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
        }
        let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard values.allSatisfy(\.isFinite), abs(norm - 1) < 0.001 else { throw EmbeddingIndexError.corruptIndex }
        return try KnowledgeVector(modelID: model.id, values: values)
    }
}
