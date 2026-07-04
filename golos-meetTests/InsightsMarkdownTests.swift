import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct InsightsMarkdownTests {
    private func insights(_ points: [ActionPoint], summary: String = "Обсудили релиз.") -> MeetingInsights {
        MeetingInsights(meetingId: "m", llmModel: "x",
                        generatedAt: Date(timeIntervalSince1970: 0), title: "Планёрка",
                        summary: summary, actionPoints: points, schemaVersion: 1)
    }

    @Test func render_includesTitleSummaryAndCheckboxes() {
        var done = ActionPoint(id: UUID(), text: "Выкатить билд", owner: "Денис")
        done.done = true
        let todo = ActionPoint(id: UUID(), text: "Написать тесты", owner: nil)
        let md = InsightsMarkdown.render(title: "Планёрка",
                                         date: Date(timeIntervalSince1970: 0),
                                         insights: insights([done, todo]))
        #expect(md.contains("# Планёрка"))
        #expect(md.contains("Обсудили релиз."))
        #expect(md.contains("- [x] Выкатить билд (Денис)"))
        #expect(md.contains("- [ ] Написать тесты"))
    }

    @Test func render_withoutActionPoints_omitsSection() {
        let md = InsightsMarkdown.render(title: "Пустая",
                                         date: Date(timeIntervalSince1970: 0),
                                         insights: insights([]))
        #expect(md.contains("# Пустая"))
        #expect(!md.contains("## Action points"))
    }
}
