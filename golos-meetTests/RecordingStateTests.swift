import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct RecordingStateTests {
    @Test func beginSetsLive_endClears_endIsIdempotent() {
        let rs = RecordingState()
        #expect(rs.live == nil)
        let t = Date(timeIntervalSince1970: 42)
        rs.begin(id: "m1", startedAt: t, isManual: true)
        #expect(rs.live == RecordingState.Live(id: "m1", startedAt: t, isManual: true))
        rs.end()
        #expect(rs.live == nil)
        rs.end()                     // идемпотентно
        #expect(rs.live == nil)
    }
}
