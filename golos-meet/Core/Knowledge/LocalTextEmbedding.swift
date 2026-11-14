import Foundation

nonisolated enum EmbeddingPurpose: Sendable { case query, passage }

/// A local-only contract. An inference implementation may download public model
/// weights, but embedding text must never be sent to a remote inference endpoint.
nonisolated protocol LocalTextEmbedding: Sendable {
    var modelID: String { get }
    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [KnowledgeVector]
}

nonisolated protocol LocalPassageEmbedding: LocalTextEmbedding {
    var dimensions: Int { get }
    func passageWindows(_ text: String) async throws -> [EmbeddedPassageWindow]
}

nonisolated enum KnowledgeVectorError: Error, Equatable {
    case invalidVector
    case incompatibleModels
    case incompatibleDimensions
}

nonisolated struct KnowledgeVector: Codable, Equatable, Sendable {
    let modelID: String
    let values: [Float]

    init(modelID: String, values: [Float]) throws {
        guard !modelID.isEmpty, !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw KnowledgeVectorError.invalidVector
        }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite && norm > 0 else { throw KnowledgeVectorError.invalidVector }
        self.modelID = modelID
        self.values = values.map { Float(Double($0) / norm) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(modelID: c.decode(String.self, forKey: .modelID),
                      values: c.decode([Float].self, forKey: .values))
    }

    func cosineSimilarity(to other: KnowledgeVector) throws -> Double {
        guard modelID == other.modelID else { throw KnowledgeVectorError.incompatibleModels }
        guard values.count == other.values.count else { throw KnowledgeVectorError.incompatibleDimensions }
        let score = zip(values, other.values).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        return min(1, max(-1, score))
    }
}
