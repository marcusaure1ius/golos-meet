import Foundation

/// Реальный агентный рантайм: локальный dsh headless (issue #94).
///
/// Один процесс на вопрос; инструменты search_meetings / summarize_meeting
/// предоставляются принятым плагином `golos-qa` (research/dsh-spike-94),
/// модель — DeepSeek V4.1 Flash через OpenRouter. Ключ передаётся ТОЛЬКО
/// через переменную окружения процесса (никогда в файлы/логи/argv),
/// источником служит Keychain профиля приложения.
@MainActor
final class DshAgentRuntime {
    enum DshError: LocalizedError {
        case emptyResponse(String)
        case timedOut
        var errorDescription: String? {
            switch self {
            case .emptyResponse(let stderr):
                return stderr.isEmpty
                    ? "Агентный рантайм вернул пустой ответ."
                    : "Агентный рантайм вернул пустой ответ: \(stderr.prefix(300))"
            case .timedOut:
                return "Агентный рантайм не ответил за 5 минут — процесс остановлен."
            }
        }
    }

    /// Каталог спайка dsh: node_modules, dsh-patch.yml, .dsh-home/profiles/golos.
    let root: URL

    init?(root: URL?) {
        guard let root,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("dsh-patch.yml").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("node_modules").path)
        else { return nil }
        self.root = root
    }

    /// Поиск каталога dsh: переопределение (defaults: agent.dshDir) →
    /// dev-расположение спайка этой машины. nil → чат работает в демо-режиме.
    static func defaultRoot(defaults: UserDefaults = .standard) -> URL? {
        if let raw = defaults.string(forKey: "agent.dshDir"), !raw.isEmpty {
            let override = URL(fileURLWithPath: raw)
            if FileManager.default.fileExists(atPath: override.appendingPathComponent("dsh-patch.yml").path) {
                return override
            }
        }
        let dev = URL(fileURLWithPath: "/Users/alfa/.codex/worktrees/94-dsh-spike/golos-meet/research/dsh-spike-94")
        return FileManager.default.fileExists(atPath: dev.appendingPathComponent("dsh-patch.yml").path) ? dev : nil
    }

    /// Чистая функция для тестов: argv запуска без шелла (инъекции исключены).
    func buildArguments(question: String) -> [String] {
        ["npx", "--no-install", "@deepseek-ai/dsh", "headless", "--patch", "./dsh-patch.yml", question]
    }

    /// Задаёт вопрос агенту и возвращает финальный ответ (stdout процесса).
    func ask(_ question: String, apiKey: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = buildArguments(question: question)
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["OPENROUTER_API_KEY"] = apiKey
        process.environment = environment

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        async let output: Data? = Task.detached(priority: .utility) {
            try? stdout.fileHandleForReading.readDataToEndOfFile()
        }.value
        async let diagnostics: Data? = Task.detached(priority: .utility) {
            try? stderr.fileHandleForReading.readDataToEndOfFile()
        }.value

        // Таймаут 5 минут: dsh сам держит агентный цикл модели (~30–90 с),
        // больший бюджет нужен только на очень длинных вопросах.
        try await Task.sleep(for: .seconds(300))
        if process.isRunning { process.terminate() }

        let answer = String(data: await output ?? Data(), encoding: .utf8) ?? ""
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let diag = String(data: await diagnostics ?? Data(), encoding: .utf8) ?? ""
            throw DshError.emptyResponse(String(diag.suffix(300)))
        }
        return answer
    }
}
