import XCTest

/// E-03 (issue #105): чат «Агент» — отправка вопроса → агент отвечает.
///
/// В изолированном test host архив пуст, ключ OpenRouter в тестовом Keychain
/// отсутствует → работает детерминированный мок-агент (демо-режим, сети нет).
///
/// Известное ограничение (macOS 27.0.1): объединённые accessibility-элементы
/// строк ленивого потока чата теряют AX-лейблы после завершения стрима
/// (staticTexts с пустыми label), поэтому тексты narration/ответа проверяет
/// эквивалентный Swift Testing сценарий в test host (AgentChatUIFlowTests),
/// а XCUITest проверяет поведение на надёжных элементах — кнопках.
final class E03AgentChatTests: GolosUITestCase {
    override var scenarioID: String { "e03-agent" }

    func testAgentRunsDemoPipelineOnQuestion() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.staticTexts["Что ищем в архиве?"].firstMatch.waitForExistence(timeout: 15),
                      "Экран «Агент» открыт (пустое состояние)")

        // Вопрос через композер.
        let field = app.textFields["Сообщение агенту"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Композер чата")
        field.click()
        field.typeText("О чём договорились на последней встрече?")

        let send = app.buttons["Отправить"].firstMatch
        XCTAssertTrue(send.exists, "Кнопка отправки активна после ввода")
        send.click()

        // Мок-агент начал работу: кнопка переключилась в «Остановить агента».
        let stop = app.buttons["Остановить агента"].firstMatch
        var sawThinking = false
        for _ in 0..<20 where !(sawThinking) {
            if stop.exists { sawThinking = true; break }
            usleep(250_000)
        }
        XCTAssertTrue(sawThinking, "Во время ответа доступна остановка агента")

        // Ответ завершился: снова «Отправить», в потоке — блок процесса.
        let sendAgain = app.buttons["Отправить"].firstMatch
        var settled = false
        for _ in 0..<60 where !settled {
            if sendAgain.exists { settled = true; break }
            usleep(500_000)
        }
        XCTAssertTrue(settled, "Агент завершил ответ")

        let toolBlock = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Раскрыть процесс")).firstMatch
        XCTAssertTrue(toolBlock.waitForExistence(timeout: 10),
                      "Свёрнутый блок процесса в потоке")

        app.terminate()
    }
}
