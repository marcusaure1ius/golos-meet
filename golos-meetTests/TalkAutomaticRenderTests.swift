import AppKit
import SwiftUI
import Testing
@testable import golos_meet

@MainActor private final class AutomaticRenderStore: TalkCredentialStoring, TalkPreferencesStoring, TalkRecordingModeStoring, TalkAutomaticModeStoring {
    let credential = TalkCredential(server: URL(string: "https://render.example")!, token: "talkusr.synthetic", version: UUID())
    let account = TalkUserAccount(key: "synthetic-owner", login: "test.owner", firstname: "Анна", surname: "Тестовая", email: "owner@example.ru")
    var hasAccount = true
    var hasCredential = true
    var automaticMode: Bool? = true
    func load() throws -> TalkCredential? { hasCredential ? credential : nil }
    func load() throws -> TalkMeetingPreferences? { .init(schemaVersion: 1, origin: credential.server, connectionVersion: credential.version!, rooms: [], account: hasAccount ? account : nil) }
    func load() throws -> Bool { false }
    func load() throws -> Bool? { automaticMode }
    func save(_ value: TalkCredential?) throws {}
    func save(_ value: TalkMeetingPreferences?) throws {}
    func save(_ enabled: Bool) throws {}
}

@MainActor @Suite struct TalkAutomaticRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_TALK_SETTINGS"] == "1"))
    func renderAutomaticStates() throws {
        #expect(AppRuntime.isTestHost)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("golos72-automatic-renders")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let states: [(String, TalkAutomaticObservation)] = [
            ("checking", .init(presence: .unknown(.checking))),
            ("permission", .init(presence: .unknown(.unavailable), nativeIssue: .permissionRequired)),
            ("unavailable", .init(presence: .unknown(.unavailable), nativeIssue: .unavailable)),
            ("present", .init(presence: .present(rooms: ["synthetic_room"]))),
            ("absent", .init(presence: .absent)),
            ("api-error", .init(presence: .unknown(.unauthorized))),
            ("no-account", .stopped),
            ("legacy-unconfigured", .stopped)
        ]
        for dark in [false, true] {
            for (name, observation) in states {
                let store = AutomaticRenderStore(); store.hasAccount = name != "no-account"
                if name == "legacy-unconfigured" { store.hasCredential = false; store.hasAccount = false; store.automaticMode = nil }
                let model = TalkMeetingSettingsModel(preferences: store, credentials: store, mode: store, automaticMode: store)
                if store.hasCredential { model.bind(store.credential) }
                let status = TalkAutomaticStatus(); status.observation = observation
                let palette = dark ? Palette.dark : Palette.light
                let content = TalkMeetingSettingsView(model: model, status: status)
                    .padding(24).frame(width: 700, height: 900, alignment: .top)
                    .background(palette.content).environment(\.palette, palette).environment(\.colorScheme, dark ? .dark : .light)
                let view = NSHostingView(rootView: content)
                view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = view
                view.layoutSubtreeIfNeeded()
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                window.contentView = nil
            }
        }
        print("Automatic settings renders: \(root.path)")
    }
}
