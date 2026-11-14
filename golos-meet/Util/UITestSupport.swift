import Foundation
import AppKit
import SwiftUI

/// Test-support hooks для XCUITest E-сценариев (issue #105). Активно только в
/// UI-test shell (`GOLOS_MEET_UI_E2E=1` при `GOLOS_MEET_TEST_MODE=1`):
/// хранилище изолировано во временном каталоге, детектор/спасение/очередь не
/// запускаются, рабочие данные пользователя не читаются и не изменяются.
@MainActor
enum UITestSupport {
    static func activate() {
        NSApp.setActivationPolicy(.regular)
        guard AppRuntime.uiTestShell else { return }
        if ProcessInfo.processInfo.environment["GOLOS_MEET_UI_E2E_FRESH"] == "1" {
            UserDefaults().removePersistentDomain(forName: AppRuntime.requireProfile().preferencesDomain)
            removeStorageContents()
        }
        if ProcessInfo.processInfo.environment["GOLOS_MEET_UI_E2E_SEED"] == "import-errors" {
            seedImportErrors()
        }
        if ProcessInfo.processInfo.environment["GOLOS_MEET_UI_E2E_ACTION"] == "set-theme-dark" {
            // Производственный путь записи настроек (didSet → AppPreferences,
            // тестовый домен) — тот же, что вызывает пункт меню темы.
            UISettings.shared.themeMode = .dark
        }
    }

    /// Раннер XCUITest запускает приложение без UI-интента: SwiftUI не создаёт
    /// стартовое окно WindowGroup (NSApp.windows пуст даже при политике
    /// regular). Окно с тем же ProductionRootView создаётся явно — только в
    /// shell-режиме, над тем же изолированным хранилищем.
    static func presentWindowIfNeeded() {
        guard AppRuntime.uiTestShell else { return }
        guard NSApp.windows.allSatisfy({ $0.contentView == nil }) else { return }
        guard let library = AppLibraryState.shared.library else { return }
        // Окно обязано целиком помещаться на видимый экран: AX-клики по
        // элементам за пределами экрана молча не срабатывают.
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1100, visible.width - 80)
        let height = min(820, visible.height - 80)
        let frame = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                           width: width, height: height)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Golos Meet"
        window.contentView = NSHostingView(rootView: ProductionRootView(library: library))
        window.setFrameAutosaveName("golos-uitest-shell")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Полный сброс изолированного хранилища между прогонами сценария.
    private static func removeStorageContents() {
        let root = AppRuntime.testStorage
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for child in children { try? FileManager.default.removeItem(at: child) }
    }

    /// Сидирование состояний ошибки импорта через принятый store (E-06):
    /// три строки в document_imports изолированной SQLite, реальные русские
    /// тексты продукта — без exception-ов. Синхронно на старте: сиды обязаны
    /// попасть в store до первого reload UI.
    private static func seedImportErrors() {
        let store = ProjectStore(url: AppPaths.appSupport.appendingPathComponent("knowledge.sqlite"))
        let seeds: [(String, DocumentImportState, String)] = [
            ("scan-without-text-layer.pdf", .failed,
             DocumentExtractionError.noText.errorDescription ?? "В документе не найден текст."),
            ("notes.docx", .cancelled, "Импорт отменён."),
            ("report.pdf", .interrupted,
             "Импорт был прерван. Выберите файл и импортируйте его снова.")
        ]
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            for (filename, state, message) in seeds {
                let id = UUID()
                try? await store.startImport(id: id, filename: filename, targetID: nil, state: state)
                try? await store.updateImport(id: id, state: state, message: message)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
    }
}
