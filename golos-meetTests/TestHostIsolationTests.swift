import AppKit
import Foundation
import Testing
@testable import golos_meet

@MainActor
@Suite struct TestHostIsolationTests {
    @Test func detectsTestHostBeforeApplicationInitialization() {
        #expect(!AppRuntime.isTestHost(environment: [:]))
        #expect(AppRuntime.isTestHost(environment: ["GOLOS_MEET_TEST_MODE": "1"]))
        #expect(AppRuntime.isTestHost(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]))
        #expect(AppRuntime.isTestHost)
        #expect(AppLibraryState().library == nil)
        #expect(ProductionIndexing.shared == nil)
        #expect(ProductionAssignments.shared == nil)
        #expect(ProductionMemoryQueue.shared == nil)
        #expect(ProductionKnowledgeSearch.service == nil)
        #expect(ProductionKnowledgeQuestions.makeModel() == nil)
    }

    @Test func defaultPathsAndLibraryUseTemporaryStorage() throws {
        let root = AppPaths.appSupport.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        #expect(root.path.hasPrefix(temporary.path + "/"))
        #expect(AppPaths.meetingsRoot.deletingLastPathComponent() == AppPaths.appSupport)
        #expect(AppPaths.modelsRoot.deletingLastPathComponent() == AppPaths.appSupport)
        #expect(Keychain.service.hasPrefix("golos-meet.tests."))

        let id = "isolation-\(UUID())"
        let folder = AppPaths.meetingDir(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("synthetic audio".utf8).write(to: folder.appendingPathComponent("mic.wav"))
        let library = MeetingLibrary()
        library.reload()
        #expect(library.summaries.contains { $0.id == id })
    }

    @Test func testLaunchDoesNotRescueRecordOrEnqueue() throws {
        // A damaged synthetic recording would be repaired/enqueued by production startup.
        let folder = AppPaths.meetingDir("unfinished-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("mic.wav")
        let original = Data("unfinished synthetic WAV".utf8)
        try original.write(to: audio)
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.coordinator == nil)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(try Data(contentsOf: audio) == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("meta.json").path))
        #expect(MeetingProcessor.shared.busyMeetingsCount == 0)
    }
}
