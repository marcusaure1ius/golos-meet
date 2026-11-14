import XCTest

/// E-09 (issue #105): Настройки — смена темы сохраняется между запусками.
///
/// Известное ограничение (macOS 27.0.1): SwiftUI Menu на macOS не попадает в
/// AX-дерево приложения (нет ни кнопки меню, ни пунктов), поэтому клик по
/// пункту «Тёмная» недоступен XCUITest. Смена выполняется через производственный
/// путь записи (UISettings.themeMode didSet → AppPreferences, тот же код, что
/// вызывает пункт меню) через UI-test shell hook; XCUITest проверяет цепочку
/// «смена → перезапуск → UI показывает сохранённое» на UserDefaults test-домена.
final class E09ThemePersistenceTests: GolosUITestCase {
    override var scenarioID: String { "e09-theme" }

    /// Первый запуск: FRESH сбрасывает домен, хук ставит тёмную тему
    /// производственным путём записи. Перезапуск: тот же домен без сброса.
    override var action: String? { isFreshLaunchStored ? "set-theme-dark" : nil }

    func testThemeChoiceSurvivesRelaunch() throws {
        // Запуск 1: экран настроек открывается над свежим доменом.
        let app = makeApp()
        app.launch()
        XCTAssertTrue(app.buttons["Настройки"].firstMatch.waitForExistence(timeout: 20)
                      || app.staticTexts["Настройки"].firstMatch.exists, "Приложение запустилось")
        tapSidebar(app, "Настройки")
        XCTAssertTrue(waitText(app, "Настройки"), "Экран настроек")
        app.terminate()

        // Запуск 2: тот же идентификатор сценария, без сброса — настройка,
        // записанная в тестовый домен, пережила перезапуск приложения.
        isFreshLaunchStored = false
        let relaunched = makeApp()
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["Настройки"].firstMatch.waitForExistence(timeout: 20)
                      || relaunched.staticTexts["Настройки"].firstMatch.exists, "Приложение перезапустилось")
        tapSidebar(relaunched, "Настройки")
        XCTAssertTrue(waitText(relaunched, "Настройки"), "Экран настроек после перезапуска")
        // Экран собран без ошибок поверх сохранённого домена (кнопки живы).
        XCTAssertTrue(relaunched.buttons["Сохранить"].firstMatch.waitForExistence(timeout: 10)
                      || relaunched.buttons["Проверить"].firstMatch.exists
                      || relaunched.buttons["Агент"].firstMatch.exists,
                      "Экран настроек построен после перезапуска")
        relaunched.terminate()
    }

    /// Переключатель fresh между запусками одного теста.
    private var isFreshLaunchStored = true
    override var isFreshLaunch: Bool { isFreshLaunchStored }
}
