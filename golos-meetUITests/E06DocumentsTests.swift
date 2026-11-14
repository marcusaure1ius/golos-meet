import XCTest

/// E-06 (issue #101, #105): Документы — история провалов импорта не показывается.
/// Ошибки сидируются через принятый store на старте приложения
/// (UITestSupport.seedImportErrors → document_imports изолированной SQLite):
/// терминальные состояния, включая старую запись с английским exception-текстом.
/// Провал импорта показывается один раз в момент провала (транзиентная карточка);
/// постоянного списка «Предыдущие попытки импорта» в UI больше нет.
final class E06DocumentsTests: GolosUITestCase {
    override var scenarioID: String { "e06-documents" }
    override var seed: String? { "import-errors" }

    func testImportFailureHistoryIsNotShown() throws {
        let app = makeApp()
        app.launch()

        tapSidebar(app, "Документы")

        // Секция истории попыток и старые английские ошибки не показываются.
        XCTAssertFalse(waitText(app, "Предыдущие попытки импорта", timeout: 8),
                       "Секции «Предыдущие попытки импорта» нет")
        XCTAssertFalse(waitText(app, "The operation couldn't be completed. (TextRecognition.CRImageReaderError error 1.)", timeout: 3),
                       "Английский exception-текст из истории не показывается")
        XCTAssertFalse(waitText(app, "scan-without-text-layer.pdf", timeout: 3),
                       "Имена попыток из истории не показываются")

        // Пустая библиотека документов — отдельное честное состояние.
        XCTAssertTrue(waitText(app, "Пока нет документов"), "Пустая библиотека документов")

        app.terminate()
    }
}
