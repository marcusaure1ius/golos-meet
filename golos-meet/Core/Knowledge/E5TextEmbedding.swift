import Foundation
import Tokenizers
import OnnxRuntimeBindings

nonisolated struct EmbeddedPassageWindow: Sendable {
    let tokenStart: Int
    let tokenCount: Int
    let vector: KnowledgeVector
}

/// CPU inference is actor-isolated and serial, never on the UI executor. Only
/// local files are opened; the Hub's remote model loader is deliberately unused.
actor E5TextEmbedding: LocalTextEmbedding {
    nonisolated let modelID = EmbeddingModelManifest.e5Small.modelID
    private let environment: ORTEnv
    private let session: ORTSession
    private let tokenizer: any Tokenizer
    private let inputs: Set<String>
    private let output: String

    init(folder: URL) async throws {
        tokenizer = try await AutoTokenizer.from(modelFolder: folder, strict: true)
        // Unigram's optional bosTokenId is not populated by this upstream
        // tokenizer; validate the artifact's special tokens and actual template.
        guard tokenizer.convertTokenToId("<s>") == 0, tokenizer.convertTokenToId("</s>") == 2,
              tokenizer.convertTokenToId("<pad>") == 1,
              tokenizer.encode(text: "query: проверка").first == 0,
              tokenizer.encode(text: "query: проверка").last == 2 else {
            throw EmbeddingModelError.incompatibleModel
        }
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        // Prevent idle spin from competing with recording and ASR.
        try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        session = try ORTSession(env: environment, modelPath: folder.appendingPathComponent("onnx/model.onnx").path,
                                 sessionOptions: options)
        inputs = Set(try session.inputNames())
        guard inputs == ["input_ids", "attention_mask", "token_type_ids"],
              try session.outputNames() == ["last_hidden_state"] else { throw EmbeddingModelError.incompatibleModel }
        output = "last_hidden_state"
    }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [KnowledgeVector] {
        try texts.map { text in
            try Task.checkCancellation()
            let tokens = try tokenIDs(text, purpose: purpose)
            guard tokens.count <= 512 else { throw EmbeddingModelError.tooLong(tokens.count) }
            return try infer(tokens)
        }
    }

    /// Long passages retain every token, including the tail. Offsets exclude
    /// prefix and special tokens and can be persisted alongside the source chunk.
    func passageWindows(_ text: String) throws -> [EmbeddedPassageWindow] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EmbeddingModelError.emptyText }
        let prefix = tokenizer.encode(text: "passage:", addSpecialTokens: false)
        let full = tokenizer.encode(text: "passage: " + text, addSpecialTokens: false)
        guard full.starts(with: prefix) else { throw EmbeddingModelError.incompatibleModel }
        let body = Array(full.dropFirst(prefix.count))
        let capacity = 512 - prefix.count - 2
        var result: [EmbeddedPassageWindow] = []
        var start = 0
        while start < body.count {
            try Task.checkCancellation()
            let end = min(start + capacity, body.count)
            let vector = try infer([0] + prefix + Array(body[start..<end]) + [2])
            result.append(.init(tokenStart: start, tokenCount: end - start, vector: vector))
            if end == body.count { break }
            start = end - 64
        }
        return result
    }

    // Internal for parity tests against the exact pinned tokenizer artifact.
    func tokenIDs(_ text: String, purpose: EmbeddingPurpose) throws -> [Int] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EmbeddingModelError.emptyText }
        return tokenizer.encode(text: (purpose == .query ? "query: " : "passage: ") + text)
    }

    private func infer(_ tokens: [Int]) throws -> KnowledgeVector {
        func tensor(_ values: [Int64]) throws -> ORTValue {
            let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
            return try ORTValue(tensorData: data, elementType: .int64, shape: [1, NSNumber(value: tokens.count)])
        }
        let values = ["input_ids": try tensor(tokens.map(Int64.init)),
                      "attention_mask": try tensor(Array(repeating: 1, count: tokens.count)),
                      "token_type_ids": try tensor(Array(repeating: 0, count: tokens.count))]
        let outputs = try session.run(withInputs: values, outputNames: [output], runOptions: nil)
        guard let value = outputs[output] else { throw EmbeddingModelError.incompatibleModel }
        let shape = try value.tensorTypeAndShapeInfo()
        guard shape.elementType == .float, shape.shape.map(\.intValue) == [1, tokens.count, 384] else {
            throw EmbeddingModelError.incompatibleModel
        }
        let data = try value.tensorData()
        guard data.length == tokens.count * 384 * MemoryLayout<Float>.stride else { throw EmbeddingModelError.incompatibleModel }
        var mean = Array(repeating: Float(0), count: 384)
        let floats = data.bytes.bindMemory(to: Float.self, capacity: tokens.count * 384)
        // Batch size one, no padding: the attention mask is all ones.
        for token in 0..<tokens.count {
            for dimension in 0..<384 { mean[dimension] += floats[token * 384 + dimension] / Float(tokens.count) }
        }
        try Task.checkCancellation()
        return try KnowledgeVector(modelID: modelID, values: mean)
    }
}
