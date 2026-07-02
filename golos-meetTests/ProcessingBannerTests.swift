import Testing
@testable import golos_meet

@MainActor
@Suite struct ProcessingBannerTests {
    @Test func pluralization() {
        #expect(ProcessingBanner.pluralize(1) == "встречу")
        #expect(ProcessingBanner.pluralize(2) == "встречи")
        #expect(ProcessingBanner.pluralize(5) == "встреч")
        #expect(ProcessingBanner.pluralize(11) == "встреч")
        #expect(ProcessingBanner.pluralize(21) == "встречу")
        #expect(ProcessingBanner.pluralize(22) == "встречи")
    }
}
