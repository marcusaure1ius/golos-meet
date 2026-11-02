import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO
import CryptoKit

nonisolated enum ProbeTrace {
    struct Scope: Sendable {
        let root: URL; let id: String; let cpu: Bool; let preflight: Bool
        init(root: URL, id: String, cpu: Bool, preflight: Bool = false) { self.root=root; self.id=id; self.cpu=cpu; self.preflight=preflight }
    }
    @TaskLocal static var scope: Scope?
    private static let lock = NSLock()
    static var threadScope: Scope? {
        get { Thread.current.threadDictionary["golos56.trace.scope"] as? Scope }
        set { Thread.current.threadDictionary["golos56.trace.scope"] = newValue }
    }
    static var currentScope: Scope? { scope ?? threadScope }
    static func beginInput(_ data: Data, _ ext: String) throws {
        guard ["pdf", "png", "jpg", "jpeg", "tif", "tiff", "heic"].contains(ext.lowercased()) else { return }
        if currentScope == nil, let folder = ProcessInfo.processInfo.environment["GOLOS_OCR_DIAGNOSTICS_56"] {
            let root = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            threadScope = Scope(root: root, id: UUID().uuidString, cpu: false)
        }
        guard let currentScope else { return }
        let file = currentScope.root.appendingPathComponent(currentScope.id + "." + ext)
        try data.write(to: file)
        event("input", ["input": file.lastPathComponent, "bytes": data.count,
             "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
    }
    static func event(_ stage: String, _ fields: [String: Any] = [:]) {
        guard let scope = currentScope else { return }
        var record = fields
        record["stage"] = stage; record["id"] = scope.id
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        record["wall"] = Date().timeIntervalSince1970
        record["executor"] = Thread.current.threadDictionary["golos56.executor"] as? String; record["strictPool"] = ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1"; record["cpuControl"] = scope.cpu; record["preflight"] = scope.preflight
        lock.lock(); defer { lock.unlock() }
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10])
            let file = scope.root.appendingPathComponent(scope.id + ".jsonl")
            if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
            let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
        } catch { fatalError("Synthetic diagnostic write failed") }
    }
    static func error(_ stage: String, _ error: any Error) {
        let ns = error as NSError
        event(stage, ["error": String(describing: error), "domain": ns.domain, "code": ns.code,
                      "description": ns.localizedDescription, "userInfo": ns.userInfo.mapValues { String(describing: $0) }])
    }
    static func image(_ stage: String, _ image: CGImage) throws {
        guard let scope = currentScope else { return }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        let bytes = data as Data
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let path = scope.root.appendingPathComponent(scope.id + "-" + hash + ".png")
        try bytes.write(to: path)
        event(stage, ["image": path.lastPathComponent, "sha256": hash, "width": image.width, "height": image.height,
                      "bitsPerPixel": image.bitsPerPixel, "bytesPerRow": image.bytesPerRow])
    }
    static func configure(_ request: VNRecognizeTextRequest) throws {
        event("request-options", ["revision": request.revision, "languages": request.recognitionLanguages,
            "automaticLanguage": request.automaticallyDetectsLanguage, "languageCorrection": request.usesLanguageCorrection])
        if currentScope?.cpu == true || currentScope?.preflight == true {
            let devices = try request.supportedComputeStageDevices
            event("cpu-supported-devices", ["devices": Dictionary(uniqueKeysWithValues: devices.map { ($0.key.rawValue, $0.value.map { String(describing: $0) }) })])
            if currentScope?.cpu != true { return }
            for (stage, candidates) in devices {
                guard let cpu = candidates.first(where: { if case .cpu = $0 { return true }; return false }) else { throw CocoaError(.featureUnsupported) }
                request.setComputeDevice(cpu, for: stage)
            }
        }
    }
    static func observations(_ request: VNRecognizeTextRequest) {
        let rows: [[String: Any]] = (request.results ?? []).map { row in
            ["candidates": row.topCandidates(5).map { ["text": $0.string, "confidence": $0.confidence] as [String: Any] },
             "x": row.boundingBox.minX, "y": row.boundingBox.minY, "width": row.boundingBox.width, "height": row.boundingBox.height]
        }
        event("perform-end", ["observations": rows])
    }
}

@main struct OCRProbe {
    static func require<T>(_ x: T?) throws -> T { guard let x else { throw CocoaError(.coderInvalidValue) }; return x }
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5, let repeats = Int(args[4]) else { fatalError("input-folder output-folder sequential|parallel default|cpu repeats") }
        let inputs = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cases: [(String, String, String)] = [
            ("png-en", "png", "Project Alpha budget approved"), ("png-ru", "png", "Решение: запуск проекта в ноябре"),
            ("mixed", "pdf", "Decision: launch postponed to December"), ("duplicate", "pdf", "Decision: launch postponed to December"),
            ("distinct", "pdf", "Approved"), ("20", "pdf", "20"), ("26", "pdf", "26"),
            ("native", "pdf", "Decision: ship in November")]
        for (id, ext, text) in cases {
            let path = inputs.appendingPathComponent(id + "." + ext)
            if FileManager.default.fileExists(atPath: path.path) { continue }
            if ext == "png" { try png(text, path) }
            else if id == "native" { try nativePDF(path) }
            else { try mixed(id == "distinct" ? "Not approved" : ((id == "20" || id == "26") ? "2026" : "Page 1"), text, id == "duplicate", path) }
        }
        if args[2] == "threads" {
            guard #available(macOS 15.0, *) else { fatalError("Independent executor control requires macOS 15+") }
            var executors: [ProbeTaskExecutor] = []
            var jobs: [Task<Void,Never>] = []
            for iteration in 0..<repeats { for item in cases {
                let executor = ProbeTaskExecutor(); executors.append(executor)
                jobs.append(Task.detached(executorPreference: executor) {
                    await run(item, iteration, inputs, output, args[3] == "cpu", args[3] != "default")
                })
            } }
            for job in jobs { await job.value }
            for executor in executors { await executor.close() }
            return
        }
        if args[2] == "fanout" {
            await withTaskGroup(of: Void.self) { group in
                for iteration in 0..<repeats { for item in cases {
                    group.addTask { await run(item, iteration, inputs, output, args[3] == "cpu", args[3] != "default") }
                } }
            }
            return
        }
        for iteration in 0..<repeats {
            if args[2] == "parallel" {
                await withTaskGroup(of: Void.self) { group in
                    for item in cases { group.addTask { await run(item, iteration, inputs, output, args[3] == "cpu", args[3] != "default") } }
                }
            } else {
                for item in cases { await run(item, iteration, inputs, output, args[3] == "cpu", args[3] != "default") }
            }
        }
    }
    nonisolated static func run(_ item: (String, String, String), _ iteration: Int, _ input: URL, _ output: URL, _ cpu: Bool, _ preflight: Bool) async {
        let (id, ext, expected) = item
        let scope = ProbeTrace.Scope(root: output, id: "\(iteration)-\(id)", cpu: cpu, preflight: preflight)
        await ProbeTrace.$scope.withValue(scope) {
            let url = input.appendingPathComponent(id + "." + ext)
            do {
                let bytes = try Data(contentsOf: url)
                ProbeTrace.event("extract-begin", ["input": url.lastPathComponent,
                    "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "bytes": bytes.count])
                let result = try await LocalDocumentExtractor().extract(from: url)
                let lines = result.blocks.map(\.text).joined(separator: "\n").components(separatedBy: .newlines)
                let matched = ext == "png" ? lines.joined().lowercased().contains(id == "png-ru" ? "ноябре" : "budget approved") : lines.filter { $0 == expected }.count == 1
                ProbeTrace.event("extract-end", ["lines": lines, "warnings": result.warnings, "expected": expected, "matched": matched,
                    "outcome": matched ? "success" : "assertion-mismatch"])
            } catch { ProbeTrace.error("extract-error", error) }
        }
    }
}
