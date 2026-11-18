import Foundation
import Testing
@testable import golos_meet

@Suite struct TalkAudioSelectionTests {
    private let main = TalkAudioProcess(processID: 10, bundleIdentifier: "kontur.talk")

    @Test func selectsOnlyConfirmedNativeApplicationsAndHelpers() throws {
        let renderer = TalkAudioProcess(processID: 12, bundleIdentifier: "kontur.talk.helper.Renderer")
        let audio = TalkAudioProcess(processID: 11, bundleIdentifier: "kontur.talk.helper")
        let foreign = ["com.google.Chrome", "com.apple.Safari", "kontur.talking",
                       "kontur.talk.fake", "kontur.talk.helper.Unknown", ""]
            .enumerated().map { TalkAudioProcess(processID: Int32(20 + $0.offset), bundleIdentifier: $0.element) }
        let selected = try TalkAudioSelection.select(foreign + [renderer, main, audio, main])
        #expect(selected == [main, audio, renderer])
    }

    @Test(arguments: ["kontur.talk.helper", "com.google.Chrome", "kontur.talk.fake", ""])
    func helperOrBrowserAloneDoesNotReplaceNativeClient(bundleID: String) {
        #expect(throws: TalkAudioCaptureError.nativeClientNotFound) {
            try TalkAudioSelection.select([TalkAudioProcess(processID: 10, bundleIdentifier: bundleID)])
        }
    }

    @Test func noSelectionHasNoAllSystemMeaning() {
        #expect(throws: TalkAudioCaptureError.nativeClientNotFound) {
            try TalkAudioSelection.select([])
        }
    }

    @Test func rejectsConflictingOrInvalidProcessIdentities() {
        #expect(throws: TalkAudioCaptureError.invalidProcesses) {
            try TalkAudioSelection.select([main, TalkAudioProcess(processID: 10, bundleIdentifier: "com.apple.Safari")])
        }
        #expect(throws: TalkAudioCaptureError.invalidProcesses) {
            try TalkAudioSelection.select([TalkAudioProcess(processID: 0, bundleIdentifier: "kontur.talk")])
        }
    }
}

@MainActor
@Suite struct TalkAudioProcessGuardTests {
    private let main = TalkAudioProcess(processID: 10, bundleIdentifier: "kontur.talk")
    private let helper = TalkAudioProcess(processID: 11, bundleIdentifier: "kontur.talk.helper")

    @Test func missingSelectedHelperFailsOnceAndDoesNotReplaceSelection() throws {
        var alive = Set([main, helper])
        let guarder = TalkAudioProcessGuard(targets: [main, helper], inspect: { alive.contains($0) })
        var failures: [TalkAudioCaptureError] = []
        try guarder.start { failures.append($0) }
        guarder.poll()
        #expect(failures.isEmpty)
        alive.remove(helper)
        alive.insert(TalkAudioProcess(processID: 12, bundleIdentifier: helper.bundleIdentifier))
        guarder.poll()
        guarder.poll()
        #expect(failures == [.processDisappeared])
    }

    @Test func discoveryFailureIsExplicitAndStopsMonitoring() throws {
        var failInspection = false
        let guarder = TalkAudioProcessGuard(targets: [main], inspect: { _ in
            if failInspection { throw NSError(domain: "synthetic-private-response", code: 1) }
            return true
        })
        var failures: [TalkAudioCaptureError] = []
        try guarder.start { failures.append($0) }
        failInspection = true
        guarder.poll()
        #expect(failures == [.sourceUnavailable])
        #expect(!failures[0].localizedDescription.contains("private-response"))
        guarder.poll()
        #expect(failures.count == 1)
    }

    @Test func missingSourceBeforeStartDoesNotBeginMonitoring() {
        let guarder = TalkAudioProcessGuard(targets: [main], inspect: { _ in false })
        var callbackCount = 0
        #expect(throws: TalkAudioCaptureError.processDisappeared) {
            try guarder.start { _ in callbackCount += 1 }
        }
        guarder.poll()
        #expect(callbackCount == 0)
    }

    @Test func explicitStopIgnoresLatePoll() throws {
        let guarder = TalkAudioProcessGuard(targets: [main], inspect: { _ in true })
        try guarder.start { _ in Issue.record("Stopped guard must not fail the next session") }
        guarder.stop()
        guarder.poll()
    }
}
