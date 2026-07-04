import Testing
import Foundation
@testable import golos_meet

@MainActor
@Suite struct MeetingStoreTests {
    private func makeMeeting(_ root: URL, _ id: String) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = MeetingMeta(id: id, source: "kontur.talk",
                               startedAt: Date(timeIntervalSince1970: 0),
                               endedAt: Date(timeIntervalSince1970: 600),
                               durationSeconds: 600, status: .ready, asrModel: "gigaam-v3",
                               title: "Старый", schemaVersion: 1)
        try meta.write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }
    private func tempRoot() throws -> URL {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }

    @Test func delete_removesFolder_andSafeOnMissing() throws {
        let root = try tempRoot()
        let dir = try makeMeeting(root, "m1")
        try MeetingStore.delete(id: "m1", root: root)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        // повторно / несуществующий — не бросает
        try MeetingStore.delete(id: "m1", root: root)
        try MeetingStore.delete(id: "nope", root: root)
    }

    @Test func rename_setsTitleAndManualFlag() throws {
        let root = try tempRoot()
        let dir = try makeMeeting(root, "m2")
        try MeetingStore.rename(id: "m2", title: "Новое имя", root: root)
        let meta = try MeetingMeta.decoded(Data(contentsOf: dir.appendingPathComponent("meta.json")))
        #expect(meta.title == "Новое имя")
        #expect(meta.titleManual == true)
    }

    @Test func setActionPointDone_togglesOnlyTarget() throws {
        let root = try tempRoot()
        let dir = try makeMeeting(root, "m3")
        let a = ActionPoint(id: UUID(), text: "A", owner: nil)
        let b = ActionPoint(id: UUID(), text: "B", owner: nil)
        let ins = MeetingInsights(meetingId: "m3", llmModel: "m",
            generatedAt: Date(timeIntervalSince1970: 0), title: "T", summary: "S",
            actionPoints: [a, b], schemaVersion: 1)
        try ins.write(to: dir.appendingPathComponent("insights.json"))

        try MeetingStore.setActionPointDone(id: "m3", actionPointId: a.id, done: true, root: root)
        let updated = try MeetingInsights.decoded(Data(contentsOf: dir.appendingPathComponent("insights.json")))
        #expect(updated.actionPoints.first { $0.id == a.id }?.done == true)
        #expect(updated.actionPoints.first { $0.id == b.id }?.done == false)
    }
}
