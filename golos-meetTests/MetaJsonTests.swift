import Testing
import Foundation
@testable import golos_meet

@Suite struct MetaJsonTests {
    @Test func encodesAndComputesDuration() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1000 + 312)
        let meta = MeetingMeta(id: "2026-06-17_17-28-05", source: "ktalk",
                               startedAt: start, endedAt: end, durationSeconds: 312)
        let data = try MeetingMeta.encoded(meta)
        let back = try JSONDecoder().decode(MeetingMeta.self, from: data)
        #expect(back == meta)
        #expect(back.durationSeconds == 312)
    }
}
