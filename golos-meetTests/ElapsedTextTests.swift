import Testing
@testable import golos_meet

@Suite struct ElapsedTextTests {
    @Test func formatsMinutesSeconds() {
        #expect(elapsedText(0) == "00:00")
        #expect(elapsedText(65) == "01:05")
        #expect(elapsedText(599) == "09:59")
    }
    @Test func formatsHours() {
        #expect(elapsedText(3661) == "1:01:01")
    }
    @Test func clampsNegative() {
        #expect(elapsedText(-5) == "00:00")
    }
}
