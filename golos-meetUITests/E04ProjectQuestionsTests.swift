import XCTest

/// E-04 (issue #113, #123): сайдбар без «Поиска»/«Вопросов» → проектный вход
/// «Вопросы» на странице проекта открывает Агента с предзаполненным контекстом.
/// Экраны «Поиск по источникам» и «Вопросы по проекту» свёрнуты в Агента;
/// поиск — инструмент агента, RAG-вопросы станут его инструментом после
/// подключения живого рантайма (демо-режим честно помечает это в интерфейсе).
///
/// Проект «Альфа» сидируется через принятый store на старте приложения
/// (UITestSupport.seedProject → projects изолированной SQLite).
final class E04ProjectQuestionsTests: GolosUITestCase {
    override var scenarioID: String { "e04-project-questions" }
    override var seed: String? { "project" }

    func testProjectQuestionsButtonOpensAgentWithPrefilledContext() throws {
        let app = makeApp()
        app.launch()

        // Сайдбар: прежних пунктов «Поиск» и «Вопросы» больше нет.
        XCTAssertTrue(app.buttons["Агент"].firstMatch.waitForExistence(timeout: 20),
                      "Сайдбар должен содержать «Агент»")
        XCTAssertFalse(app.buttons["Поиск"].firstMatch.exists, "Пункта «Поиск» нет в сайдбаре")
        XCTAssertFalse(app.buttons["Вопросы"].firstMatch.exists, "Пункта «Вопросы» нет в сайдбаре")

        // Страница проекта.
        tapSidebar(app, "Альфа")
        let questions = app.buttons["project.questions"].firstMatch
        XCTAssertTrue(questions.waitForExistence(timeout: 15), "Кнопка «Вопросы» на странице проекта")

        questions.click()

        // Кнопка ведёт в Агента, контекст проекта предзаполнен в поле черновика.
        XCTAssertTrue(waitLabelContains(app, "Экран Агент", timeout: 15), "Открыт экран «Агент»")
        let field = app.textFields["Сообщение агенту"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Композер чата Агента")
        var draft = ""
        for _ in 0..<20 where draft.isEmpty {
            draft = (field.value as? String) ?? ""
            if draft.isEmpty { usleep(250_000) }
        }
        XCTAssertTrue(draft.contains("Проект: Альфа"), "Черновик предзаполнен контекстом проекта, получили: «\(draft)»")

        // Честная пометка демо-режима: RAG-вопросы по всем проектам — после
        // подключения живого рантайма.
        XCTAssertTrue(waitText(app, "Пометка демо-режима агента", timeout: 10),
                      "Пометка демо-режима с честным статусом RAG видна")

        app.terminate()
    }
}
