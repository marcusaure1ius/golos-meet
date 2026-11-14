import AppKit
import SwiftUI
import Testing
@testable import golos_meet

/// E-09-эквивалент (issue #105): смена темы переживает «перезапуск» —
/// новый экземпляр UISettings над тем же UserDefaults-доменом читает
/// сохранённое значение. XCUITest E-09 прогоняет ту же цепочку через два
/// реальных запуска приложения (запись — производственный путь UISettings).
@MainActor
@Suite struct ThemePersistenceUITests {

    @Test func themeChoiceSurvivesNewSettingsInstance() throws {
        let suiteName = "golos-e2e-theme-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            Issue.record("Тестовый домен UserDefaults недоступен")
            return
        }
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Запуск 1: свежий домен — тема по умолчанию; смена пользователем.
        let first = UISettings(defaults: suite)
        #expect(first.themeMode == .auto)
        first.themeMode = .dark

        // Запуск 2: новый экземпляр над тем же доменом.
        let second = UISettings(defaults: suite)
        #expect(second.themeMode == .dark, "Выбранная тема сохранилась после перезапуска")
    }

    /// Рендер экрана настроек с обеими темами меню — по явному запросу
    /// (GOLOS_MEET_RENDER_UI_E2E). SettingsScreen читает UISettings.shared;
    /// в test host это изолированный тестовый домен.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_UI_E2E"].map { !$0.isEmpty } == true))
    func renderSettingsThemeStates() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_UI_E2E"]!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = UISettings.shared.themeMode
        defer { UISettings.shared.themeMode = original }
        for (name, mode) in [("e09-theme-auto", UISettings.ThemeMode.auto),
                             ("e09-theme-dark", .dark)] {
            UISettings.shared.themeMode = mode
            for dark in [false, true] {
                let palette = dark ? Palette.dark : Palette.light
                let content = SettingsScreen()
                    .frame(width: 860, height: 700)
                    .background(palette.content)
                    .environment(\.palette, palette)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: 860, height: 700)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: root.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                window.contentView = nil
            }
        }
        print("UI-E2E renders: \(root.path)")
    }
}
