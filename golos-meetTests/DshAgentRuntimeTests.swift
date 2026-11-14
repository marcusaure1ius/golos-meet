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
}
