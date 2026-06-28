import Testing
import Foundation
@testable import golos_meet

@Suite struct MeetingStatusMetaTests {
    @Test func decodesOldMetaWithoutStatus() throws {
        let json = #"""
        {"durationSeconds":2505,"endedAt":"2026-06-26T09:42:51Z","id":"X",
         "source":"kontur.talk","startedAt":"2026-06-26T09:01:06Z"}
        """#
        let meta = try MeetingMeta.decoded(Data(json.utf8))
        #expect(meta.status == nil)
        #expect(meta.asrModel == nil)
        #expect(meta.durationSeconds == 2505)
    }

    @Test func roundTripsWithStatus() throws {
        let m = MeetingMeta(id: "X", source: "kontur.talk",
                            startedAt: Date(timeIntervalSince1970: 1000),
                            endedAt: Date(timeIntervalSince1970: 1312),
                            durationSeconds: 312,
                            status: .ready, asrModel: "gigaam-v3")
        let back = try MeetingMeta.decoded(MeetingMeta.encoded(m))
        #expect(back == m)
        #expect(back.status == .ready)
    }
}
