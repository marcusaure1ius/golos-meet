import Testing
@testable import golos_meet

@MainActor
struct MeetingFeedPageTests {
    @Test func repeatedFooterDoesNotSkipAPage() {
        var page = MeetingFeedPage()
        #expect(page.limit == 30)

        page.loadMore(after: 30, total: 65)
        page.loadMore(after: 30, total: 65)
        #expect(page.limit == 60)

        page.loadMore(after: 60, total: 65)
        page.loadMore(after: 90, total: 65)
        #expect(page.limit == 90)
    }

    @Test func emptyAndFullFirstPageDoNotExpand() {
        var page = MeetingFeedPage()
        page.loadMore(after: 30, total: 0)
        page.loadMore(after: 30, total: 30)
        #expect(page.limit == 30)
    }
}
