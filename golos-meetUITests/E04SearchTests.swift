import XCTest

/// E-04 (issue #105): переход на Поиск → ввод запроса → пустое состояние.
/// В UI-test shell поиск работает над пустым изолированным хранилищем:
/// лексический поиск честно возвращает «ничего не найдено», семантика
/// сообщает про отсутствие локальной модели (индексация не запускается).
final class E04SearchTests: GolosUITestCase {
    override var scenarioID: String { "e04-search" }

    func testSearchEmptyStateOnIsolatedStore() throws {
        let app = makeApp()
        app.launch()

        tapSidebar(app, "Поиск")
        XCTAssertTrue(waitText(app, "Поиск по источникам"), "Экран поиска открыт")

        let field = app.textFields["Поисковый запрос"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Поле запроса")
        field.click()
        field.typeText("прайсинг")

        let find = app.buttons["Найти"].firstMatch
        XCTAssertTrue(find.exists)
        find.click()

        // Честное сообщение о недоступной семантике без модели индексации.
        XCTAssertTrue(waitText(app, "Для поиска по смыслу установите модель в настройках. Сейчас ищем совпадения слов.", timeout: 20),
                      "Сообщение семантического слоя")
        // Пустое состояние выдачи.
        XCTAssertTrue(waitText(app, "В индексе ничего не найдено", timeout: 20),
                      "Пустое состояние поиска на пустом изолированном индексе")

        app.terminate()
    }
}
