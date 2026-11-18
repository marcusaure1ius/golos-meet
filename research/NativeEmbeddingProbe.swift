// Developer-only CLI, built with the same production Swift files and pinned
// SwiftPM objects. It does not construct the app, Keychain or meeting library.
import Foundation
import Darwin

@main struct NativeEmbeddingProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: native-embedding-probe MODEL_FOLDER REPORT_JSON\n", stderr)
            exit(2)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let verifier = EmbeddingModelInstaller(root: folder)
        let start = ProcessInfo.processInfo.systemUptime
        try await verifier.verifyFolder(folder)
        let verified = ProcessInfo.processInfo.systemUptime
        let encoder = try await E5TextEmbedding(folder: folder)
        let loaded = ProcessInfo.processInfo.systemUptime
        let vector = try await encoder.embed(["Почему изменили срок начала эксперимента?"], purpose: .query)[0]
        let finished = ProcessInfo.processInfo.systemUptime
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["model_id": encoder.modelID, "dimensions": vector.values.count,
                                   "verification_seconds": verified - start, "load_seconds": loaded - verified,
                                   "query_ms": (finished - loaded) * 1000, "peak_rss_bytes": usage.ru_maxrss,
                                   "vector_head": Array(vector.values.prefix(16)), "synthetic_text_only": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print("Native E5 probe passed (\(vector.values.count) dimensions).")
    }
}
