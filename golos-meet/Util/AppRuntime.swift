import Foundation

/// Resolved before App/StateObject initialization, including in an Xcode test host.
enum AppRuntime {
    static func isTestHost(environment: [String: String]) -> Bool {
        environment["GOLOS_MEET_TEST_MODE"] == "1"
            || ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCInjectBundleInto"]
                .contains { environment[$0] != nil }
    }

    static let isTestHost = isTestHost(environment: ProcessInfo.processInfo.environment)

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
