import Testing
import Foundation
@testable import golos_meet

@Suite struct ASRModelTests {
    @Test func speedMapsToGigaamDir() {
        #expect(ASRModelChoice.speed.engine == .gigaam)
        #expect(ASRModelChoice.speed.modelPath.lastPathComponent == "gigaam-v3")
    }

    @Test func qualityMapsToWhisperBin() {
        #expect(ASRModelChoice.quality.engine == .whisper)
        #expect(ASRModelChoice.quality.modelPath.lastPathComponent == "ggml-large-v3.bin")
    }

    @Test func loadEncodesKind() throws {
        let data = try JSONEncoder().encode(SidecarRequest.load(id: 1, modelPath: "/m", kind: .whisper))
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"kind\":\"whisper\""))
        #expect(s.contains("\"model_path\":\"\\/m\"") || s.contains("\"model_path\":\"/m\""))
    }
}
