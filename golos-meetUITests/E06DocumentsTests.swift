import XCTest

/// E-06 (issue #105): Документы — состояние ошибки импорта с русским текстом.
/// Ошибки сидируются через принятый store на старте приложения
/// (UITestSupport.seedImportErrors → document_imports изолированной SQLite):
/// три терминальных состояния с реальными русскими сообщениями продукта.
final class E06DocumentsTests: GolosUITestCase {
    override var scenarioID: String { "e06-documents" }
    override var seed: String? { "import-errors" }

    func testImportErrorStatesShowRussianMessages() throws {
        let app = makeApp()
        app.launch()

        tapSidebar(app, "Документы")
        XCTAssertTrue(waitText(app, "Предыдущие попытки импорта", timeout: 20),
                      "Секция предыдущих попыток")

        // Русские тексты ошибок (не exception) — по одному на состояние.
        XCTAssertTrue(waitText(app, "В документе не найден текст, доступный для индексации."),
                      "Сообщение ошибки распознавания (failed)")
        XCTAssertTrue(waitText(app, "Импорт отменён."),
                      "Сообщение отмены (cancelled)")
        XCTAssertTrue(waitText(app, "Импорт был прерван. Выберите файл и импортируйте его снова."),
                      "Сообщение прерывания (interrupted)")

        // Структура: имя файла сидированной попытки и кнопка повтора
        // (a11y-лейбл кнопки — «Выбрать файл для повтора импорта …»).
        XCTAssertTrue(waitText(app, "scan-without-text-layer.pdf"), "Имя файла попытки")
        XCTAssertTrue(waitLabelContains(app, "Выбрать файл для повтора импорта"),
                      "Кнопка повтора импорта")

        // Пустая библиотека документов — отдельное честное состояние.
        XCTAssertTrue(waitText(app, "Пока нет документов"), "Пустая библиотека документов")

        app.terminate()
    }
}
