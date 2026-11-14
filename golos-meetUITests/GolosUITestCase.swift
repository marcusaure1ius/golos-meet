import XCTest

/// База E-сценариев (issue #105). Каждый запуск приложения изолирован:
/// GOLOS_MEET_TEST_MODE=1 + GOLOS_MEET_UI_E2E=1 держат приложение на временных
/// путях с тестовым Keychain; детектор, спасение записей и автообработка не
/// запускаются, рабочие данные пользователя не читаются и не изменяются.
///
/// Известное ограничение macOS UI-тестирования: раннер должен быть подписан.
/// Прогон выполняется с ad-hoc подписью (`CODE_SIGN_IDENTITY=-`); с
/// `CODE_SIGNING_ALLOWED=NO` раннер убивается до установления AX-соединения.
class GolosUITestCase: XCTestCase {

    /// Стабильный идентификатор сценария: изолированное хранилище и домен
    /// настроек одни и те же для всех запусков внутри сценария.
    var scenarioID: String { "shared" }

    /// Первый запуск сценария сбрасывает изолированное хранилище и домен настроек.
    var isFreshLaunch: Bool { true }

    /// Сидирование через store на старте приложения (см. UITestSupport).
    var seed: String? { nil }

    /// Действие на старте приложения через производственный путь (см. UITestSupport).
    var action: String? { nil }

    func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GOLOS_MEET_TEST_MODE"] = "1"
        app.launchEnvironment["GOLOS_MEET_UI_E2E"] = "1"
        app.launchEnvironment["GOLOS_MEET_UI_E2E_ID"] = scenarioID
        if isFreshLaunch { app.launchEnvironment["GOLOS_MEET_UI_E2E_FRESH"] = "1" }
        if let seed { app.launchEnvironment["GOLOS_MEET_UI_E2E_SEED"] = seed }
        if let action { app.launchEnvironment["GOLOS_MEET_UI_E2E_ACTION"] = action }
        app.launchArguments += ["-AppleLanguages", "(ru)"]
        return app
    }

    // MARK: - Хелперы навигации

    /// Клик по строке сайдбара: кнопка навигации или её текст.
    func tapSidebar(_ app: XCUIApplication, _ title: String) {
        let row = app.buttons[title].firstMatch
        if row.waitForExistence(timeout: 10) {
            row.click()
            return
        }
        let text = app.staticTexts[title].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), "Сайдбар должен содержать «\(title)»")
        text.click()
    }

    func waitText(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 15) -> Bool {
        app.staticTexts[text].firstMatch.waitForExistence(timeout: timeout)
            || app.otherElements[text].firstMatch.waitForExistence(timeout: 2)
            || app.descendants(matching: .any)[text].firstMatch.exists
    }

    /// Элемент по подстроке label: объединённые accessibility-элементы
    /// (children: .combine) не совпадают по точной строке.
    func waitLabelContains(_ app: XCUIApplication, _ fragment: String, timeout: TimeInterval = 15) -> Bool {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
        return query.waitForExistence(timeout: timeout)
    }
}
