import Testing
import Foundation
@testable import golos_meet

/// Интеграция реального рантайма dsh в чат «Агент» (issue #94).
@MainActor
struct DshAgentRuntimeTests {
    /// Каталог-фикстура с dsh-patch.yml — без node_modules и без запуска npx.
    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data("test: true".utf8).write(to: dir.appendingPathComponent("dsh-patch.yml"))
        return dir
    }

    @Test func initAcceptsRootWithPatch() throws {
        let root = try makeRoot()
        let runtime = DshAgentRuntime(root: root)
        #expect(runtime != nil)
        #expect(runtime?.root == root)
    }

    @Test func initRejectsRootWithoutPatch() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(DshAgentRuntime(root: empty) == nil)
        #expect(DshAgentRuntime(root: nil) == nil)
    }

    @Test func buildArgumentsPassesQuestionAsSingleArgument() throws {
        let runtime = try #require(DshAgentRuntime(root: makeRoot()))
        let args = runtime.buildArguments(question: "О чём договорились? «кавычки» и --не-флаг")
        #expect(args == ["npx", "--no-install", "@deepseek-ai/dsh", "headless",
                         "--patch", "./dsh-patch.yml", "О чём договорились? «кавычки» и --не-флаг"])
    }

    @Test func chatWithoutRuntimeStaysInDemoMode() throws {
        let library = MeetingLibrary(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-demo-\(UUID().uuidString)"))
        let model = AgentChatModel(library: library, stepDelay: .zero)
        #expect(model.modeDescription.contains("Демо-режим"))
    }

    @Test func chatWithRuntimeAndKeySwitchesToLiveMode() throws {
        let library = MeetingLibrary(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-live-\(UUID().uuidString)"))
        let model = AgentChatModel(library: library,
                                   stepDelay: .zero,
                                   runtime: DshAgentRuntime(root: try makeRoot()),
                                   runtimeAPIKey: { "test-key" })
        #expect(model.modeDescription.contains("Живой агент"))
    }

    @Test func chatWithRuntimeButEmptyKeyStaysInDemoMode() throws {
        let library = MeetingLibrary(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-nokey-\(UUID().uuidString)"))
        let model = AgentChatModel(library: library,
                                   stepDelay: .zero,
                                   runtime: DshAgentRuntime(root: try makeRoot()),
                                   runtimeAPIKey: { "" })
        #expect(model.modeDescription.contains("Демо-режим"))
    }

    // MARK: - stripLeadingPreamble (#103)

    /// Прецедент из #103: английская мета-фраза перед русским ответом.
    @Test func stripsEnglishPreambleBeforeCyrillic() {
        let answer = "I have enough grounded material. Here's the answer, drawing on the November pricing meetings.\n\nДоговорились по прайсингу: ..."
        let stripped = DshAgentRuntime.stripLeadingPreamble(answer)
        #expect(stripped.hasPrefix("Договорились"))
        #expect(!stripped.contains("I have enough"))
    }

    /// Преамбула перед markdown-заголовком тоже обрезается.
    @Test func stripsPreambleBeforeMarkdownHeading() {
        let answer = "Sure, here is what I found.\n## Договорённости по прайсингу\nЦитаты с таймкодами..."
        let stripped = DshAgentRuntime.stripLeadingPreamble(answer)
        #expect(stripped.hasPrefix("## Договорённости"))
    }

    /// Ответ сразу на русском не меняется (граница в позиции 0 < 200).
    @Test func pureRussianAnswerUnchanged() {
        let answer = "  \nПо прайсингу договорились — цитаты ниже.  \n"
        let stripped = DshAgentRuntime.stripLeadingPreamble(answer)
        #expect(stripped == "По прайсингу договорились — цитаты ниже.")
    }

    /// Преамбула длиннее 200 символов не обрезается: это может быть
    /// содержательный ASCII-ответ, рисковать им нельзя.
    @Test func longPreambleKeptUnchanged() {
        let preamble = String(repeating: "Working on it. ", count: 20) // 300 символов
        let answer = preamble + "\n\nРусский ответ."
        #expect(DshAgentRuntime.stripLeadingPreamble(answer) == answer)
    }

    /// ASCII-ответ без заголовков и кириллицы возвращается без изменений:
    /// границы содержимого нет, что считать преамбулой — неизвестно.
    @Test func asciiAnswerWithoutBoundaryUnchanged() {
        let answer = "The archive contains 3 matching quotes about pricing."
        #expect(DshAgentRuntime.stripLeadingPreamble(answer) == answer)
    }

    /// Кириллица внутри преамбулы останавливает обрезку на первом таком
    /// символе — начало содержимого.
    @Test func boundaryAtFirstCyrillicInsidePreamble() {
        let answer = "OK. Пример: договорились по прайсингу."
        let stripped = DshAgentRuntime.stripLeadingPreamble(answer)
        #expect(stripped.hasPrefix("Пример:"))
    }
}
