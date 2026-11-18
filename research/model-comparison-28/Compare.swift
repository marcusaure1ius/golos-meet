// Research-only native CLI. No App, AppPaths, Keychain, ASR or production library.
import Foundation
import CryptoKit
import Darwin
import Tokenizers
import Hub
import OnnxRuntimeBindings

nonisolated struct Asset: Codable { let path: String; let bytes: Int; let sha256: String; let required_for_inference: Bool }
nonisolated struct Model: Codable {
    let id: String; let repository: String; let revision: String; let license: String
    let query_prefix: String; let passage_prefix: String; let max_tokens: Int; let dimensions: Int
    let files: [Asset]
}
nonisolated struct Models: Codable { let models: [Model] }
nonisolated struct Passage: Codable { let id: String; let topic: String; let text: String }
nonisolated struct Question: Codable { let id: String; let text: String; let relevant_ids: [String] }
nonisolated struct Corpus: Codable { let passages: [Passage]; let queries: [Question] }
nonisolated struct TokenFixture: Codable { let text: String; let purpose: String; let ids: [Int] }
nonisolated struct TokenFixtures: Codable { let fixtures: [String: [TokenFixture]] }
nonisolated enum Failure: Error { case invalid(String) }

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.invalid(message) }
}
func hashFile(_ path: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: path); defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func peakRSS() -> Int64 {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Int64(usage.ru_maxrss)
}
func localTokenizer(_ model: Model, folder: URL) throws -> any Tokenizer {
    // Identical local JSON loading for both candidates, without Hub/network loaders.
    var config = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("tokenizer_config.json"))) as! [String: Any]
    let data = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("tokenizer.json"))) as! [String: Any]
    try require((data["model"] as? [String: Any])?["type"] as? String == "Unigram", "Expected Unigram")
    if model.id == "minilm" {
        try require(config["tokenizer_class"] as? String == "PreTrainedTokenizerFast", "Unexpected MiniLM tokenizer class")
        config["tokenizer_class"] = "XLMRobertaTokenizer"
    }
    return try PreTrainedTokenizer(tokenizerConfig: Config(config as [NSString: Any]),
                                  tokenizerData: Config(data as [NSString: Any]), strict: true)
}
func pool(_ hidden: [Float], mask: [Int64], dimensions: Int) throws -> [Float] {
    try require(hidden.count == mask.count * dimensions && mask.contains(1), "Invalid pooling shape/mask")
    var mean = Array(repeating: Float(0), count: dimensions)
    let count = Float(mask.reduce(0, +))
    for token in mask.indices where mask[token] == 1 {
        for d in 0..<dimensions { mean[d] += hidden[token * dimensions + d] / count }
    }
    let norm = sqrt(mean.reduce(0) { $0 + Double($1) * Double($1) })
    try require(norm.isFinite && norm > 0, "Invalid embedding norm")
    return mean.map { Float(Double($0) / norm) }
}
func dot(_ a: [Float], _ b: [Float]) -> Double {
    zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
}
func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    if p == 0.5 && sorted.count % 2 == 0 {
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
    return sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)]
}
func selfTest() throws {
    let result = try pool([1, 3, 3, 5, 99, 99], mask: [1, 1, 0], dimensions: 2)
    try require(abs(Double(result[0]) - 1 / sqrt(5)) < 0.000001, "Masked mean failed")
    try require(abs(dot(result, result) - 1) < 0.000001, "L2/dot failed")
    try require(percentile([4, 1, 3, 2], 0.5) == 2.5, "Median convention failed")
}

@MainActor final class Encoder {
    let model: Model
    let tokenizer: any Tokenizer
    let environment: ORTEnv
    let session: ORTSession
    let output: String
    let inputNames: [String]
    let tokenizerLoadSeconds: Double
    init(_ model: Model, folder: URL) async throws {
        self.model = model
        let start = ProcessInfo.processInfo.systemUptime
        tokenizer = try localTokenizer(model, folder: folder)
        tokenizerLoadSeconds = ProcessInfo.processInfo.systemUptime - start
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        session = try ORTSession(env: environment, modelPath: folder.appendingPathComponent("onnx/model.onnx").path,
                                 sessionOptions: options)
        inputNames = try session.inputNames()
        try require(Set(inputNames) == ["input_ids", "attention_mask", "token_type_ids"], "Unexpected inputs")
        let outputs = try session.outputNames()
        try require(outputs.contains("last_hidden_state"), "Expected token-level last_hidden_state: \(outputs)")
        output = "last_hidden_state"
    }
    func tokens(_ text: String, purpose: String) -> [Int] {
        tokenizer.encode(text: (purpose == "query" ? model.query_prefix : model.passage_prefix) + text)
    }
    func embed(_ text: String, purpose: String) throws -> (vector: [Float], tokens: Int) {
        try autoreleasepool {
        let ids = tokens(text, purpose: purpose)
        try require(!text.isEmpty && ids.count <= model.max_tokens, "Over context limit: \(ids.count)/\(model.max_tokens)")
        try require(ids.first == 0 && ids.last == 2, "Unexpected special-token template")
        let mask = Array(repeating: Int64(1), count: ids.count)
        func tensor(_ values: [Int64]) throws -> ORTValue {
            let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
            return try ORTValue(tensorData: data, elementType: .int64, shape: [1, NSNumber(value: ids.count)])
        }
        let input = ["input_ids": try tensor(ids.map(Int64.init)), "attention_mask": try tensor(mask),
                     "token_type_ids": try tensor(Array(repeating: 0, count: ids.count))]
        let outputs = try session.run(withInputs: input, outputNames: [output], runOptions: nil)
        guard let value = outputs[output] else { throw Failure.invalid("Missing output") }
        let shape = try value.tensorTypeAndShapeInfo()
        try require(shape.elementType == .float && shape.shape.map(\.intValue) == [1, ids.count, model.dimensions], "Invalid output shape")
        let data = try value.tensorData()
        let count = ids.count * model.dimensions
        try require(data.length == count * MemoryLayout<Float>.stride, "Invalid tensor length")
        let hidden = Array(UnsafeBufferPointer(start: data.bytes.bindMemory(to: Float.self, capacity: count), count: count))
        return (try pool(hidden, mask: mask, dimensions: model.dimensions), ids.count)
        }
    }
}

@main struct Compare {
    @MainActor static func main() async throws {
        try selfTest()
        if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
            print("Masked pooling, L2, dot and percentile self-tests passed."); return
        }
        guard CommandLine.arguments.count == 7 else {
            fputs("Usage: compare MODEL_ID MODEL_FOLDER RESEARCH_FOLDER REPORT_JSON VECTORS_JSON_OR_DASH REPETITION\n", stderr); exit(2)
        }
        let id = CommandLine.arguments[1], folder = URL(fileURLWithPath: CommandLine.arguments[2])
        let research = URL(fileURLWithPath: CommandLine.arguments[3])
        let models = try JSONDecoder().decode(Models.self, from: Data(contentsOf: research.appendingPathComponent("models.json")))
        guard let model = models.models.first(where: { $0.id == id }) else { throw Failure.invalid("Unknown model") }
        let corpusURL = research.appendingPathComponent("corpus.json")
        let corpusHash = try hashFile(corpusURL)
        try require(corpusHash == "1e1173bfa57d645539117f3752ba54b00c82670980c88b5026a42aa764eeb5a0", "Corpus changed after preregistration")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
        try require(corpus.passages.count == 48 && corpus.queries.count == 20, "Unexpected corpus")
        let verificationStart = ProcessInfo.processInfo.systemUptime
        for asset in model.files where asset.required_for_inference {
            let path = folder.appendingPathComponent(asset.path)
            let bytes = try path.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            try require(bytes.fileSize == asset.bytes && bytes.isSymbolicLink != true, "Invalid file: \(asset.path)")
            try require(try hashFile(path) == asset.sha256, "Checksum mismatch: \(asset.path)")
        }
        let initStart = ProcessInfo.processInfo.systemUptime
        let verificationRSS = peakRSS()
        let encoder = try await Encoder(model, folder: folder)
        let loaded = ProcessInfo.processInfo.systemUptime
        let initializedRSS = peakRSS()
        let fixtureSet = try JSONDecoder().decode(TokenFixtures.self, from: Data(contentsOf: research.appendingPathComponent("token-fixtures.json")))
        let fixtures = fixtureSet.fixtures[id] ?? []
        try require(fixtures.count >= 3, "Missing tokenizer parity fixtures")
        for fixture in fixtures {
            try require(encoder.tokens(fixture.text, purpose: fixture.purpose) == fixture.ids, "Tokenizer reference mismatch")
        }
        let long = String(repeating: "проверка ", count: 700)
        try require(encoder.tokens(long, purpose: "query").count > model.max_tokens, "Hidden tokenizer truncation")
        let firstStart = ProcessInfo.processInfo.systemUptime
        _ = try encoder.embed(corpus.queries[0].text, purpose: "query")
        let firstMS = (ProcessInfo.processInfo.systemUptime - firstStart) * 1000
        let indexStart = ProcessInfo.processInfo.systemUptime
        var documents: [[Float]] = [], passageTokens: [Int] = []
        for passage in corpus.passages {
            let embedded = try encoder.embed(passage.text, purpose: "passage")
            documents.append(embedded.vector); passageTokens.append(embedded.tokens)
        }
        let indexSeconds = ProcessInfo.processInfo.systemUptime - indexStart
        let indexRSS = peakRSS()
        var queryTimes: [Double] = [], queryVectors: [[Float]] = [], queryTokens: [Int] = []
        for round in 0..<10 {
            for query in corpus.queries {
                let start = ProcessInfo.processInfo.systemUptime
                let embedded = try encoder.embed(query.text, purpose: "query")
                queryTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                if round == 0 { queryVectors.append(embedded.vector); queryTokens.append(embedded.tokens) }
            }
        }
        var ranks: [[String: Any]] = [], recallSum = 0.0, top1 = 0
        for (i, query) in corpus.queries.enumerated() {
            var ranked: [(String, Double)] = []
            for (offset, passage) in corpus.passages.enumerated() {
                ranked.append((passage.id, dot(queryVectors[i], documents[offset])))
            }
            ranked.sort { left, right in left.1 == right.1 ? left.0 < right.0 : left.1 > right.1 }
            let relevant = Set(query.relevant_ids)
            let hits = ranked.prefix(5).filter { relevant.contains($0.0) }.count
            if relevant.contains(ranked[0].0) { top1 += 1 }
            recallSum += Double(hits) / Double(relevant.count)
            ranks.append(["query_id": query.id, "hits_at_5": hits, "relevant_count": relevant.count,
                          "ranking": ranked.map { ["id": $0.0, "cosine": $0.1] as [String: Any] }])
        }
        if CommandLine.arguments[5] != "-" {
            let evidence: [String: Any] = ["model_id": id, "corpus_sha256": corpusHash,
                "passage_ids": corpus.passages.map(\.id), "query_ids": corpus.queries.map(\.id),
                "passage_vectors": documents, "query_vectors": queryVectors]
            try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[5]), options: .atomic)
        }
        let finalRSS = peakRSS()
        let report: [String: Any] = ["model_id": id, "revision": model.revision, "repetition": CommandLine.arguments[6],
            "corpus_sha256": corpusHash, "native_runtime": "Swift + ONNX Runtime 1.24.2 + Swift Transformers 1.3.5",
            "threads_intra_op": 2, "batch_size": 1, "verification_seconds": initStart - verificationStart,
            "initialization_seconds": loaded - initStart, "first_query_ms": firstMS,
            "tokenizer_load_seconds": encoder.tokenizerLoadSeconds,
            "index_seconds": indexSeconds, "index_passages_per_second": 48 / indexSeconds,
            "index_tokens_per_second": Double(passageTokens.reduce(0,+)) / indexSeconds,
            "query_ms": queryTimes, "query_median_ms": percentile(queryTimes, 0.5), "query_p95_ms": percentile(queryTimes, 0.95),
            "passage_token_counts": passageTokens, "query_token_counts": queryTokens,
            "top1": Double(top1) / 20, "top1_hits": top1, "recall_at_5_macro": recallSum / 20,
            "peak_process_rss_bytes": finalRSS,
            "phase_peak_rss_bytes": ["verification": verificationRSS, "initialized": initializedRSS, "indexed": indexRSS, "after_vectors": finalRSS],
            "required_model_bytes": model.files.filter(\.required_for_inference).reduce(0) { $0 + $1.bytes },
            "tokenizer_parity_checked": true, "mask_pooling_l2_self_test": true,
            "inputs": encoder.inputNames, "token_output": encoder.output, "queries": ranks,
            "disk_cache_reset": false, "synthetic_only": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[4]), options: .atomic)
        print("Completed native benchmark \(id), process \(CommandLine.arguments[6]).")
    }
}
