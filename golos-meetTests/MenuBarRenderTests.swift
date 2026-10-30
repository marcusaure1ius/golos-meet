import AppKit
import Foundation
import Testing
@testable import golos_meet

/// Explicit UI preview in the isolated host; no detector, audio or network.
/// TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW=1 xcodebuild test ... -only-testing:golos-meetTests/MenuBarRenderTests
@MainActor
@Suite struct MenuBarRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLOS_MEET_MENU_PREVIEW"] == "1"))
    func nativeMenuConstructionAndRendering() throws {
        #expect(AppRuntime.isTestHost)
        let controller = MenuBarController(onToggleRecording: {}, onOpenWindow: {}, onQuit: {})
        controller.install()
        defer { controller.uninstall() }
        let now = Date()
        let live = RecordingState.Live(id: "synthetic", startedAt: now.addingTimeInterval(-65), isManual: true)
        let states = [
            MenuBarModel.from(live: nil, now: now, phase: .starting, microphone: .ready, system: .waiting),
            MenuBarModel.from(live: live, now: now, phase: .recording),
            MenuBarModel.from(live: live, now: now, phase: .stopping),
            MenuBarModel.from(live: nil, now: now, phase: .failed("Запись прервана. Проверьте разрешения и свободное место."),
                              microphone: .stopped, system: .failed),
        ]
        for model in states {
            controller.render(model)
            #expect(controller.statusItem?.button?.title == " \(model.buttonTitle)")
            #expect(controller.statusItem?.menu?.items[0].title == model.statusLine)
            #expect(controller.statusItem?.menu?.items[1].title == model.tracksLine)
            #expect(controller.statusItem?.menu?.items[3].isEnabled == model.canToggle)
        }
        let menu = try #require(controller.statusItem?.menu)
        #expect(menu.size.width > 0)
        #expect(menu.size.height > 0)
    }
}
