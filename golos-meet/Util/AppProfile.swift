import Foundation

/// Pure bundle-metadata contract. No filesystem, preferences or Keychain access.
nonisolated enum AppProfile: Equatable, Sendable {
    case normal
    case isolatedQA(String)
    case testing(String)

    static let normalBundleID = "com.golos.golos-meet"
    static let qaBundlePrefix = "com.golos.golos-meet.qa."
    static let qaDisplayName = "Golos Meet QA"
    static let profileKey = "GolosRuntimeProfile"
    static let identifierKey = "GolosPreviewIdentifier"
    static let qaVersion = "isolated-qa-v1"

    enum Failure: Error, LocalizedError {
        case invalidMetadata
        var errorDescription: String? {
            "Профиль этой копии Golos Meet повреждён или не поддерживается. Используйте заново подготовленный QA-пакет. Рабочие данные не открывались."
        }
    }

    static func resolve(info: [String:Any], isTestHost: Bool, testIdentifier: String) throws -> AppProfile {
        // Test host wins even over malformed preview metadata, before any real service.
        if isTestHost {
            guard !testIdentifier.isEmpty, testIdentifier.count <= 128,
                  testIdentifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw Failure.invalidMetadata }
            return .testing(testIdentifier)
        }
        let id = info["CFBundleIdentifier"] as? String
        let marked = info[profileKey] != nil || info[identifierKey] != nil
        if !marked, id == normalBundleID,
           info["CFBundleDisplayName"] as? String != qaDisplayName,
           info["CFBundleName"] as? String != qaDisplayName { return .normal }
        guard info[profileKey] as? String == qaVersion,
              let identifier = info[identifierKey] as? String,
              identifier.count == 32,
              identifier.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              id == qaBundlePrefix + identifier,
              info["CFBundleDisplayName"] as? String == qaDisplayName,
              info["CFBundleName"] as? String == qaDisplayName else { throw Failure.invalidMetadata }
        return .isolatedQA(identifier)
    }

    var storageComponent: String {
        switch self {
        case .normal: "golos-meet"
        case .isolatedQA(let id): "golos-meet-qa-" + id
        case .testing(let id): id
        }
    }
    var keychainService: String {
        switch self {
        case .normal: "golos-meet"
        case .isolatedQA(let id): "golos-meet.qa." + id
        case .testing(let id): "golos-meet.tests." + id
        }
    }
    var preferencesDomain: String {
        switch self {
        case .normal: Self.normalBundleID
        case .isolatedQA(let id): Self.qaBundlePrefix + id
        case .testing(let id): "com.golos.golos-meet.tests." + id
        }
    }
    var isQA: Bool { if case .isolatedQA = self { return true }; return false }
    func storageRoot(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(storageComponent,isDirectory:true)
    }
}

enum AppPreferences {
    static let current: UserDefaults = {
        let profile = AppRuntime.requireProfile()
        if profile == .normal { return .standard }
        guard let defaults = UserDefaults(suiteName:profile.preferencesDomain) else {
            preconditionFailure("Cannot create isolated preferences domain")
        }
        return defaults
    }()
}
