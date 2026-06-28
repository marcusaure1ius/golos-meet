import Testing
import Foundation
@testable import golos_meet

@Suite struct AppPathsTests {
    @Test func modelDirIsUnderModelsRoot() {
        let dir = AppPaths.modelDir("gigaam-v3")
        #expect(dir.lastPathComponent == "gigaam-v3")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "models")
    }

    // NOTE (F): Тест sidecarBinary с GOLOS_MEET_ASR_BIN не реализован намеренно.
    // ProcessInfo.processInfo.environment отражает среду на момент запуска процесса
    // и не может быть изменён изнутри теста. Инъекция через launchEnvironment требует
    // отдельного UI-тест-таргета. Поведение покрыто code-review и ручной проверкой
    // в dev-запуске (GM_GRACE_SECONDS/GOLOS_MEET_ASR_BIN задаётся перед запуском).
}
