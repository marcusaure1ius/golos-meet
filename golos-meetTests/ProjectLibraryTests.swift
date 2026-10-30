import Foundation
import Testing
@testable import golos_meet

@MainActor
@Suite struct ProjectLibraryTests {
    @Test func createAssignReassignAndReloadScopes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        let library = ProjectLibrary(store: ProjectStore(url: url))
        #expect(!library.isReady)
        await library.reload()
        #expect(library.isReady)
        let a = try await library.create(name: "А", parentID: nil)
        let b = try await library.create(name: "Б", parentID: a.id)
        #expect(library.path(for: b.id) == "А / Б")
        #expect(ProjectMeetingScope.inbox.contains("M", snapshot: library.snapshot))
        try await library.assign(meetingID: "M", projectIDs: [a.id, b.id])
        #expect(ProjectMeetingScope.all.contains("M", snapshot: library.snapshot))
        #expect(ProjectMeetingScope.project(a.id).contains("M", snapshot: library.snapshot))
        #expect(ProjectMeetingScope.project(b.id).contains("M", snapshot: library.snapshot))
        #expect(!ProjectMeetingScope.inbox.contains("M", snapshot: library.snapshot))
        let restarted = ProjectLibrary(store: ProjectStore(url: url))
        await restarted.reload()
        #expect(restarted.projectIDs(for: "M") == [a.id, b.id])
        do {
            try await library.assign(meetingID: "M", projectIDs: [UUID()])
            Issue.record("Unknown project accepted")
        } catch { #expect(library.projectIDs(for: "M") == [a.id, b.id]) }
        try await library.assign(meetingID: "M", projectIDs: [])
        #expect(ProjectMeetingScope.inbox.contains("M", snapshot: library.snapshot))
        await restarted.reload()
        #expect(restarted.projectIDs(for: "M").isEmpty)
    }

    @Test func openErrorIsVisibleAndRetryRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-library-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("knowledge.sqlite")
        try Data("corrupt".utf8).write(to: url)
        let library = ProjectLibrary(store: ProjectStore(url: url))
        await library.reload()
        #expect(!library.isReady)
        #expect(library.loadError != nil)
        #expect(!library.isLoading)
        try FileManager.default.removeItem(at: url)
        await library.reload()
        #expect(library.isReady)
        #expect(library.loadError == nil)
    }
}
