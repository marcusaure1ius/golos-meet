import Foundation

/// Resolved before App/StateObject initialization, including in an Xcode test host.
enum AppRuntime {
    static func isTestHost(environment: [String: String]) -> Bool {
        environment["GOLOS_MEET_TEST_MODE"] == "1"
            || ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCInjectBundleInto"]
                .contains { environment[$0] != nil }
    }

    static let isTestHost = isTestHost(environment: ProcessInfo.processInfo.environment)

    /// UI-test shell (issue #105): XCUITest запускает приложение с
    /// GOLOS_MEET_TEST_MODE=1 плюс GOLOS_MEET_UI_E2E=1. Изоляция та же, что у
    /// test host (временные пути, тестовый Keychain, без детектора/спасения/
    /// автообработки); единственное отличие — главное окно строится над пустым
    /// изолированным хранилищем, чтобы E-сценарии видали реальный UI.
    static func uiTestShell(environment: [String: String]) -> Bool {
        isTestHost(environment: environment) && environment["GOLOS_MEET_UI_E2E"] == "1"
    }

    static let uiTestShell = uiTestShell(environment: ProcessInfo.processInfo.environment)

    /// Стабильный идентификатор сценария: повторные запуски приложения внутри
    /// одного UI-сценария должны получать то же хранилище и домен настроек
    /// (персистентность темы, E-09). Без переменной — прежнее поведение
    /// (уникальный каталог на процесс).
    static func uiTestIdentifier(environment: [String: String]) -> String? {
        guard let id = environment["GOLOS_MEET_UI_E2E_ID"], (1...32).contains(id.count),
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                                    || (97...122).contains($0) || $0 == 45 }) else { return nil }
        return "uitest-\(id)"
    }

    static let uiTestIdentifier = uiTestIdentifier(environment: ProcessInfo.processInfo.environment)

    static let profileResolution: Result<AppProfile, Error> = Result {
        try AppProfile.resolve(info:Bundle.main.infoDictionary ?? [:],isTestHost:isTestHost,
                               testIdentifier:isTestHost ? testStorage.lastPathComponent : "")
    }
    static var profileFailure: String? {
        if case .failure(let error) = profileResolution { return error.localizedDescription }
        return nil
    }
    /// Only used after the startup gate; never choose production on bad metadata.
    static func requireProfile() -> AppProfile {
        guard case .success(let profile) = profileResolution else {
            preconditionFailure("Invalid runtime profile; startup must remain closed")
        }
        return profile
    }

    /// Never fall back to production storage if isolation cannot be created.
    static let testStorage: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("golos-meet-tests-\(uiTestIdentifier ?? UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            fatalError("Cannot create isolated test storage: \(error)")
        }
        return root
    }()
}
