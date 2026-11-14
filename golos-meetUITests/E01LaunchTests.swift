import XCTest

/// E-01 (issue #105): запуск приложения (QA/test-режим) → окно → сайдбар
/// содержит «Агент», лента загружается; в изолированном test host архив пуст —
/// проверяем честное пустое состояние.
final class E01LaunchTests: GolosUITestCase {
    override var scenarioID: String { "e01-launch" }

    func testLaunchShowsSidebarAndEmptyFeed() throws {
        let app = makeApp()
        app.launch()

        // Окно приложения появилось, сайдбар содержит «Агент».
        XCTAssertTrue(app.buttons["Агент"].firstMatch.waitForExistence(timeout: 20)
                      || app.staticTexts["Агент"].firstMatch.exists,
                      "Сайдбар должен содержать «Агент»")
        XCTAssertTrue(app.staticTexts["Golos Meet"].firstMatch.exists, "Заголовок сайдбара")

        // Лента встреч в пустом архиве — честное пустое состояние.
        tapSidebar(app, "Встречи")
        XCTAssertTrue(waitText(app, "Пока нет встреч"),
                      "Пустая лента должна показать «Пока нет встреч»")

        // Возврат на «Агент» — дефолтная секция отвечает.
        tapSidebar(app, "Агент")
        XCTAssertTrue(waitText(app, "Что ищем в архиве?"),
                      "Экран «Агент» показывает пустое состояние чата")

        app.terminate()
    }
}
