import Foundation
import SQLite3
import Testing
@testable import golos_meet

@Suite struct ProjectStoreTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func projectMembershipsSurviveRestartWithoutChangingMeetingFiles() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = root.appendingPathComponent("meetings/2026-10-30_12-00-00")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let originals = ["mic.wav": Data([0, 2, 255, 8]), "system.wav": Data([10, 20]),
                         "meta.json": Data("{\"id\":\"synthetic\"}".utf8), "transcript.json": Data("{}".utf8)]
        for (name, data) in originals { try data.write(to: meeting.appendingPathComponent(name)) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        let store = ProjectStore(url: url)
        let a = try await store.createProject(name: "  Первый проект \n")
        let b = try await store.createProject(name: "Второй", parentID: a.id)
        #expect(a.name == "Первый проект")
        #expect(a.cloudPolicy == .localOnly)
        try await store.assignMeeting(meeting.lastPathComponent, to: [a.id, b.id])
        let reopened = ProjectStore(url: url)
        let state = try await reopened.snapshot()
        #expect(state.projects.count == 2)
        #expect(state.projects.first { $0.id == b.id }?.parentID == a.id)
        #expect(state.meetingProjects[meeting.lastPathComponent] == [a.id, b.id])
        for (name, data) in originals { #expect(try Data(contentsOf: meeting.appendingPathComponent(name)) == data) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: meeting.path).count == originals.count)
        try await reopened.assignMeeting(meeting.lastPathComponent, to: [b.id])
        #expect(try await store.snapshot().meetingProjects[meeting.lastPathComponent] == [b.id])
        try await reopened.assignMeeting(meeting.lastPathComponent, to: [])
        #expect(try await store.snapshot().meetingProjects[meeting.lastPathComponent] == nil)
        #expect(try await ProjectStore(url: url).snapshot().projects.count == 2)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT origin FROM meeting_decisions", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "manual")
        for (name, data) in originals { #expect(try Data(contentsOf: meeting.appendingPathComponent(name)) == data) }
    }

    @Test func invalidAssignmentRollsBackAndRepeatingAssignmentDoesNotDuplicate() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("knowledge.sqlite"))
        let project = try await store.createProject(name: "Кавычки ' ; DROP TABLE projects; --")
        try await store.assignMeeting("M", to: [project.id])
        try await store.assignMeeting("M", to: [project.id])
        await #expect(throws: ProjectStoreError.missingProject) {
            try await store.assignMeeting("M", to: [project.id, UUID()])
        }
        #expect(try await store.snapshot().meetingProjects["M"] == [project.id])
        #expect(try await store.snapshot().projects == [project])
        await #expect(throws: ProjectStoreError.invalidName) { try await store.createProject(name: " \n") }
        await #expect(throws: ProjectStoreError.invalidName) { try await store.createProject(name: String(repeating: "а", count: 201)) }
        await #expect(throws: ProjectStoreError.invalidMeetingID) { try await store.assignMeeting("", to: []) }
    }

    @Test func futureSchemaIsRejectedWithoutChangingDatabase() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES ('keep'); PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let original = try Data(contentsOf: url)
        await #expect(throws: ProjectStoreError.newerSchema(99)) { try await ProjectStore(url: url).snapshot() }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func corruptDatabaseAndFailedMigrationPreserveOriginal() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        let original = Data("not sqlite, preserve me".utf8)
        try original.write(to: url)
        await #expect(throws: (any Error).self) { try await ProjectStore(url: url).snapshot() }
        #expect(try Data(contentsOf: url) == original)
        try FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE meeting_projects(keep TEXT); INSERT INTO meeting_projects VALUES ('old')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let previous = try Data(contentsOf: url)
        await #expect(throws: (any Error).self) { try await ProjectStore(url: url).snapshot() }
        #expect(try Data(contentsOf: url) == previous)
    }
}
