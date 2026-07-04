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
        let back = try MeetingMeta.decoded(data)
        #expect(back == meta)
        #expect(back.durationSeconds == 312)
    }

    @Test func titleManual_roundTripsAndDefaultsNil() throws {
        let meta = MeetingMeta(id: "m", source: "kontur.talk",
                               startedAt: Date(timeIntervalSince1970: 0),
                               endedAt: Date(timeIntervalSince1970: 60),
                               durationSeconds: 60, status: .ready, asrModel: nil)
        #expect(meta.titleManual == nil)
        let decoded = try MeetingMeta.decoded(MeetingMeta.encoded(meta))
        #expect(decoded.titleManual == nil)

        var manual = meta
        manual.titleManual = true
        let decodedManual = try MeetingMeta.decoded(MeetingMeta.encoded(manual))
        #expect(decodedManual.titleManual == true)
    }
}
