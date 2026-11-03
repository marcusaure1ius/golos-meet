import Foundation

/// Resolved before App/StateObject initialization, including in an Xcode test host.
enum AppRuntime {
    static func isTestHost(environment: [String: String]) -> Bool {
        environment["GOLOS_MEET_TEST_MODE"] == "1"
            || ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCInjectBundleInto"]
                .contains { environment[$0] != nil }
    }

    static let isTestHost = isTestHost(environment: ProcessInfo.processInfo.environment)

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
            .appendingPathComponent("golos-meet-tests-\(UUID())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            fatalError("Cannot create isolated test storage: \(error)")
        }
        return root
    }()
}
