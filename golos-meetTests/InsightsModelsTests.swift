import Testing
import Foundation
@testable import golos_meet

@Suite struct InsightsModelsTests {
    @Test func roundTripEncodesISO8601AndDecodes() throws {
        let ins = MeetingInsights(
            meetingId: "2026-06-30_14-00-00",
            llmModel: "qwen/qwen3.6-flash",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Синхрон по релизу",
            summary: "Договорились перенести бету.",
            actionPoints: [
                ActionPoint(id: UUID(), text: "Чейнджлог", owner: "Денис"),
                ActionPoint(id: UUID(), text: "Дата с QA", owner: nil),
            ],
            schemaVersion: 1)
        let data = try MeetingInsights.encoded(ins)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"2023-11-14T22:13:20Z\"")) // ISO-8601 для generatedAt
        let back = try MeetingInsights.decoded(data)
        #expect(back == ins)
        #expect(back.actionPoints[1].owner == nil)
    }

    @Test func actionPoint_doneDefaultsFalse_andDecodesLegacy() throws {
        // Новый round-trip
        let ap = ActionPoint(id: UUID(), text: "сделать", owner: nil)
        #expect(ap.done == false)
        var checked = ap; checked.done = true
        let data = try JSONEncoder().encode(checked)
        let back = try JSONDecoder().decode(ActionPoint.self, from: data)
        #expect(back.done == true)

        // Legacy JSON без поля done → false
        let legacy = #"{"id":"\#(UUID().uuidString)","text":"старый"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ActionPoint.self, from: legacy)
        #expect(decoded.done == false)
    }
}
