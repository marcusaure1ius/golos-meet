import AppKit
import SwiftUI
import Testing
@testable import golos_meet

@MainActor
private struct RenderTalkStore: TalkCredentialStoring {
    func load() throws -> TalkCredential? { nil }
    func save(_ credential: TalkCredential?) throws {}
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
            let success = TalkConnectionModel(store: RenderTalkStore(), checkProfile: { _ in })
            success.newToken = "talkusr.synthetic"
            await success.verify()
            try render(success, name: "connected", dark: dark, root: root)
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
        }
        print("Talk settings renders: \(root.path)")
    }

    private func render(_ model: TalkConnectionModel, name: String, dark: Bool, root: URL) throws {
        let palette = dark ? Palette.dark : Palette.light
        let content = TalkConnectionSettings(model: model)
            .padding(24)
            .frame(width: 700, height: 560, alignment: .top)
            .background(palette.content)
            .environment(\.palette, palette)
            .environment(\.colorScheme, dark ? .dark : .light)
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 560)
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
