import Testing
import Foundation
@testable import golos_meet

@Suite struct SidecarProtocolTests {
    @Test func encodesTranscribeFileSnakeCase() throws {
        let data = try JSONEncoder().encode(SidecarRequest.transcribeFile(id: 2, path: "/tmp/a.wav"))
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"type\":\"transcribe_file\""))
        #expect(s.contains("\"path\":\"\\/tmp\\/a.wav\"") || s.contains("\"path\":\"/tmp/a.wav\""))
    }

    @Test func decodesSegmentsResponse() throws {
        let json = #"{"type":"segments","id":2,"duration_ms":1500,"segments":[{"start":0.0,"end":1.5,"text":"привет"}]}"#
        let resp = try JSONDecoder().decode(SidecarResponse.self, from: Data(json.utf8))
        #expect(resp == .segments(id: 2, segments: [TimedSegment(start: 0, end: 1.5, text: "привет")], durationMs: 1500))
        #expect(resp.id == 2)
    }

    @Test func decodesError() throws {
        let json = #"{"type":"error","id":2,"kind":"wav_read_failed","message":"nope"}"#
        let resp = try JSONDecoder().decode(SidecarResponse.self, from: Data(json.utf8))
        #expect(resp == .error(id: 2, kind: "wav_read_failed", message: "nope"))
    }

    /// Ошибка без поля `id` (sidecar шлёт при ранних сбоях до получения запроса).
    @Test func decodesErrorWithoutId() throws {
        let json = #"{"type":"error","kind":"x","message":"y"}"#
        let resp = try JSONDecoder().decode(SidecarResponse.self, from: Data(json.utf8))
        #expect(resp == .error(id: nil, kind: "x", message: "y"))
    }

    /// Приветственное сообщение sidecar.
    @Test func decodesHello() throws {
        let json = #"{"type":"hello","version":"1.0"}"#
        let resp = try JSONDecoder().decode(SidecarResponse.self, from: Data(json.utf8))
        #expect(resp == .hello(version: "1.0"))
    }
}
