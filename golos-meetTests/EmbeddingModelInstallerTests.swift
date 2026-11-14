import Foundation
import CryptoKit
import Testing
@testable import golos_meet

private actor EmbeddingValidationCheckpoint {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func mark() { entered = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor @Suite struct EmbeddingModelInstallerTests {
    private func fixture() throws -> (URL, URL, EmbeddingModelManifest) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embedding-test-\(UUID())")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let data = Data("synthetic model fixture; no inference".utf8)
        try data.write(to: source.appendingPathComponent("model.bin"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (root, source, .init(repository: "test/fixture", revision: "1", modelID: "fixture", assets: [
            .init(path: "model.bin", bytes: Int64(data.count), sha256: digest)
        ]))
    }

    @Test func managesIndependentCopyAndDetectsTampering() async throws {
        let (root, source, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = EmbeddingModelInstaller(root: root.appendingPathComponent("managed"), manifest: manifest, validateRuntime: { _ in })
        let installed = try await installer.install(from: source) { _ in }
        try FileManager.default.removeItem(at: source)
        #expect(try await installer.installedFolder() == installed)
        var bytes = try Data(contentsOf: installed.appendingPathComponent("model.bin"))
        bytes[0] ^= 1
        try bytes.write(to: installed.appendingPathComponent("model.bin"))
        await #expect(throws: EmbeddingModelError.self) { try await installer.installedFolder() }
    }

    @Test func failedRuntimeAndCancelledInstallPreservePreviousActivation() async throws {
        let (root, source, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed")
        let good = EmbeddingModelInstaller(root: managed, manifest: manifest, validateRuntime: { _ in })
        let original = try await good.install(from: source) { _ in }
        let bad = EmbeddingModelInstaller(root: managed, manifest: manifest, validateRuntime: { _ in
            throw EmbeddingModelError.incompatibleModel
        })
        await #expect(throws: EmbeddingModelError.self) { try await bad.install(from: source) { _ in } }
        #expect(try await good.installedFolder() == original)
        let checkpoint = EmbeddingValidationCheckpoint()
        let cancellation = EmbeddingModelInstaller(root: managed, manifest: manifest, validateRuntime: { _ in
            await checkpoint.mark()
            try await Task.sleep(for: .seconds(10))
        })
        let task = Task { try await cancellation.install(from: source) { _ in } }
        await checkpoint.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await good.installedFolder() == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: managed.path).filter { $0.hasPrefix(".install-") }.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: managed.path).count == 2)
    }

    @Test func rejectsWrongRevisionMissingFileAndSymlinkWithoutActivation() async throws {
        let (root, source, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = EmbeddingModelInstaller(root: root.appendingPathComponent("managed"), manifest: manifest, validateRuntime: { _ in })
        let file = source.appendingPathComponent("model.bin")
        let original = try Data(contentsOf: file)
        var corrupt = original; corrupt[0] ^= 1
        try corrupt.write(to: file)
        await #expect(throws: EmbeddingModelError.self) { try await installer.install(from: source) { _ in } }
        try FileManager.default.removeItem(at: file)
        await #expect(throws: EmbeddingModelError.self) { try await installer.install(from: source) { _ in } }
        let external = root.appendingPathComponent("external.bin")
        try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        await #expect(throws: EmbeddingModelError.self) { try await installer.install(from: source) { _ in } }
        #expect(try await installer.installedFolder() == nil)
        #expect(try Data(contentsOf: external) == original)
    }
}
