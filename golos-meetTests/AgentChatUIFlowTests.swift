import AppKit
import SwiftUI
import Testing
@testable import golos_meet

/// E-03-эквивалент и U-05 (issue #105) в test host.
///
/// XCUITest-сценарий чата проверяет поведение на кнопках: объединённые
/// accessibility-элементы строк ленивого потока теряют AX-лейблы после
/// завершения стрима (macOS 27.0.1), поэтому полный контент ответа —
/// narration, блок шагов, честный ответ на пустом архиве — проверяется здесь
/// над реальными вью и моделью, а шапка чата рендерится в двух режимах (U-05).
@MainActor
@Suite struct AgentChatUIFlowTests {

    /// Полный поток E-03: вопрос → narration + блок шагов + ответ мок-агента.
    @Test func questionProducesNarrationStepsAndHonestAnswerOnEmptyArchive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-ui-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Пустой архив изолированного test host.
        let model = AgentChatModel(library: MeetingLibrary(root: root), stepDelay: .zero)

        #expect(model.modeDescription.contains("Демо-режим"), "Без ключа в тестовом Keychain — демо-режим")
        model.draft = "О чём договорились на последней встрече?"
        model.send()
        #expect(model.isThinking, "Агент начал работу")
        let limit = ContinuousClock.now + .seconds(8)
        while model.isThinking {
            guard ContinuousClock.now < limit else { Issue.record("Агент не завершил ответ"); break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(model.items.contains { if case .userMessage(_, let text, _) = $0 { return text == "О чём договорились на последней встрече?" }; return false })
        #expect(model.items.contains { if case .narration(_, let text) = $0 { return text == "Просматриваю архив встреч…" }; return false })
        #expect(model.items.contains { if case .toolSteps = $0 { return true }; return false }, "Свёрнутый блок процесса")
        #expect(model.items.contains { if case .agentMessage(_, let text, _) = $0 {
            return text == "В архиве пока нет расшифрованных встреч, поэтому ответить по данным не получится. Запишите встречу и вернитесь к этому вопросу."
        }; return false }, "Честный ответ мок-агента на пустом архиве")

        try renderFlowState(model: model)
    }

    // MARK: - U-05: шапка чата отражает фактический режим

    @Test func headerReflectsDemoAndLiveModes() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-ui-flow-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let demo = AgentChatModel(library: MeetingLibrary(root: root))
        #expect(demo.modeDescription == "Демо-режим: отвечает по правилам на данных архива, без модели")

        // Живой режим: валидный корень dsh (файловая структура, без сети) + ключ.
        let dshRoot = root.appendingPathComponent("dsh-fixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dshRoot.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try? Data("synthetic".utf8).write(to: dshRoot.appendingPathComponent("dsh-patch.yml"))
        guard let runtime = DshAgentRuntime(root: dshRoot) else {
            Issue.record("DshAgentRuntime должен конструироваться над синтетическим корнем")
            return
        }
        let live = AgentChatModel(library: MeetingLibrary(root: root),
                                  runtime: runtime,
                                  runtimeAPIKey: { "synthetic-key" })
        #expect(live.modeDescription == "Живой агент · DeepSeek V4.1 Flash")

        if let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_AGENT_CHAT"], !output.isEmpty {
            let renderRoot = URL(fileURLWithPath: output)
            try? FileManager.default.createDirectory(at: renderRoot, withIntermediateDirectories: true)
            for dark in [false, true] {
                capture(name: "u05-header-demo-\(dark ? "dark" : "light")",
                        model: demo, dark: dark, root: renderRoot)
                capture(name: "u05-header-live-\(dark ? "dark" : "light")",
                        model: live, dark: dark, root: renderRoot)
            }
            print("UI-E2E renders: \(renderRoot.path)")
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Рендер

    /// Финальное состояние потока E-03 — только по явному запросу.
    private func renderFlowState(model: AgentChatModel) throws {
        guard let output = ProcessInfo.processInfo.environment["GOLOS_MEET_RENDER_AGENT_CHAT"], !output.isEmpty else { return }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dark in [false, true] {
            capture(name: "e03-agent-answer-\(dark ? "dark" : "light")", model: model, dark: dark, root: root)
        }
        print("UI-E2E renders: \(root.path)")
    }

    private func capture(name: String, model: AgentChatModel, dark: Bool, root: URL) {
        let palette = dark ? Palette.dark : Palette.light
        let content = AgentChatView(model: model)
            .frame(width: 760, height: 620)
            .background(palette.content)
            .environment(\.palette, palette)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: root.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }
}
