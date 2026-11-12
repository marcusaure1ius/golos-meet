import AppKit
import SwiftUI
import Testing
@testable import golos_meet

@MainActor
private final class RenderTalkStore: TalkCredentialStoring {
    var value: TalkCredential?
    func load() throws -> TalkCredential? { value }
    func save(_ credential: TalkCredential?) throws { value = credential }
}

@MainActor private final class RenderWindowCredentials: TalkCredentialStoring {
    var value = TalkCredential(server: URL(string: "https://render.example")!, token: "talkusr.synthetic", version: UUID())
    func load() throws -> TalkCredential? { value }
    func save(_ value: TalkCredential?) throws { if let value { self.value = value } }
}
@MainActor private final class RenderWindowPreferences: TalkPreferencesStoring {
    var value: TalkMeetingPreferences?
    func load() throws -> TalkMeetingPreferences? { value }
    func save(_ value: TalkMeetingPreferences?) throws { self.value = value }
}
@MainActor private struct RenderWindowMode: TalkRecordingModeStoring {
    func load() throws -> Bool { true }
    func save(_ value: Bool) throws {}
}

/// Opt-in native renders, with an in-memory store and synthetic transport only.
/// TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS=1 make check
@MainActor
@Suite struct TalkConnectionRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_TALK_SETTINGS"] == "1"))
    func renderConnectionStates() async throws {
        #expect(AppRuntime.isTestHost)
        let root = AppRuntime.testStorage.appendingPathComponent("talk-settings-renders")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dark in [false, true] {
            let empty = TalkConnectionModel(store: RenderTalkStore(), checkProfile: { _ in })
            try render(empty, name: "empty", dark: dark, root: root)
            let savedStore = RenderTalkStore()
            let success = TalkConnectionModel(store: savedStore, checkProfile: { _ in })
            success.newToken = "talkusr.synthetic"
            #expect(success.save())
            await success.verify()
            try render(success, name: "connected", dark: dark, root: root)
            let reopened = TalkConnectionModel(store: savedStore, checkProfile: { _ in })
            try render(reopened, name: "saved", dark: dark, root: root)
            reopened.newToken = "talkusr.replacement"
            try render(reopened, name: "replacement", dark: dark, root: root)
            reopened.newToken = ""
            reopened.serverAddress = "https://other.example"
            try render(reopened, name: "changed-address", dark: dark, root: root)
            reopened.delete()
            try render(reopened, name: "deleted", dark: dark, root: root)
            let failure = TalkConnectionModel(store: RenderTalkStore(), checkProfile: { _ in throw TalkAPIError.unauthorized })
            failure.newToken = "talkusr.synthetic"
            await failure.verify()
            try render(failure, name: "error", dark: dark, root: root)
            let loading = TalkConnectionModel(store: RenderTalkStore(), checkProfile: { _ in
                try await Task.sleep(for: .seconds(30))
            })
            loading.newToken = "talkusr.synthetic"
            let task = Task { await loading.verify() }
            await Task.yield()
            #expect(loading.diagnostic == .checking)
            try render(loading, name: "loading", dark: dark, root: root)
            task.cancel()
            await task.value
            let credentials = RenderWindowCredentials(), preferences = RenderWindowPreferences()
            preferences.value = .init(schemaVersion: 1, origin: credentials.value.server, connectionVersion: credentials.value.version!,
                                      rooms: ["syntheticroom"], account: .init(key: "synthetic-owner", login: "owner", firstname: "Тест", surname: "Аккаунт", email: "owner@example.ru"))
            let first = TalkConnectionModel(store: credentials, preferences: preferences, mode: RenderWindowMode())
            let stale = TalkConnectionModel(store: credentials, preferences: preferences, mode: RenderWindowMode())
            #expect(stale.meetingSettings.isReadyForAPI)
            first.newToken = "talkusr.replacement"; #expect(first.save())
            #expect(stale.meetingSettings.apiEnabled && !stale.meetingSettings.isReadyForAPI)
            #expect(stale.meetingSettings.confirmed == nil)
            try render(stale, name: "stale-window", dark: dark, root: root)
        }
        // Only synthetic artifacts, stable handoff path for visual inspection.
        let handoff = FileManager.default.temporaryDirectory.appendingPathComponent("golos41-stale-window-renders")
        try FileManager.default.createDirectory(at: handoff, withIntermediateDirectories: true)
        for name in ["stale-window-light.png", "stale-window-dark.png"] {
            try Data(contentsOf: root.appendingPathComponent(name)).write(to: handoff.appendingPathComponent(name))
        }
        let connectionHandoff = FileManager.default.temporaryDirectory.appendingPathComponent("golos69-connection-renders")
        try FileManager.default.createDirectory(at: connectionHandoff, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try Data(contentsOf: file).write(to: connectionHandoff.appendingPathComponent(file.lastPathComponent))
        }
        print("Talk settings renders: \(root.path)")
    }

    private func render(_ model: TalkConnectionModel, name: String, dark: Bool, root: URL) throws {
        let palette = dark ? Palette.dark : Palette.light
        let content = TalkConnectionSettings(model: model)
            .padding(24)
            .frame(width: 700, height: 1350, alignment: .top)
            .background(palette.content)
            .environment(\.palette, palette)
            .environment(\.colorScheme, dark ? .dark : .light)
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 1350)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        window.contentView = nil
    }
}
