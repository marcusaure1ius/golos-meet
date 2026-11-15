import Foundation
import Testing
@testable import golos_meet

/// Проектный вход «Вопросы» → Агент (#113, #123): подсказка проекта
/// предзаполняет поле черновика чата («Проект: <имя> — »), пользователь
/// продолжает вопрос. Навигация и предзаполнение покрыты E-04 (XCUITest).
@Suite struct AgentProjectPromptTests {
    @Test func draftPrefillsProjectContextHint() {
        #expect(AgentProjectPrompt.draft(projectName: "Альфа") == "Проект: Альфа — ")
        #expect(AgentProjectPrompt.draft(projectName: "Название с пробелами")
                .hasPrefix("Проект: Название с пробелами — "))
    }
}
