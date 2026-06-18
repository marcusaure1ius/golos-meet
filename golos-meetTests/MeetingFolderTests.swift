import Testing
import Foundation
@testable import golos_meet

@Suite struct MeetingFolderTests {
    @Test func idFormatIsTimestamp() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 17
        comps.hour = 17; comps.minute = 28; comps.second = 5
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let folder = MeetingFolder.make(startedAt: date, source: "ktalk")
        #expect(folder.id == "2026-06-17_17-28-05")
        #expect(folder.url.lastPathComponent == "2026-06-17_17-28-05")
        #expect(folder.source == "ktalk")
    }
}
