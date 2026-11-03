import Foundation
import Security

/// Минимальная обёртка над keychain (generic password) для секретов приложения.
enum Keychain {
    enum Failure: LocalizedError {
        case operationFailed
        case invalidProfile
        var errorDescription: String? {
            switch self {
            case .operationFailed: "Не удалось обратиться к Keychain. Разрешите доступ и повторите действие."
            case .invalidProfile: "Профиль этой копии приложения не позволяет открыть Keychain."
            }
        }
    }
    private static var serviceResolution: Result<String, Error> { AppRuntime.profileResolution.map(\.keychainService) }
    static var service: String { AppRuntime.requireProfile().keychainService }
    static let openRouterAccount = "openrouter-api-key"
    static let talkAccount = "kontur-talk-api-key"

    /// Checked operations for connection settings: never claim a secret was saved
    /// when macOS denied access. The error deliberately contains no secret/data.
    static func readChecked(account: String) throws -> Data? {
        guard case .success(let service) = serviceResolution else { throw Failure.invalidProfile }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure.operationFailed }
        return data
    }

    static func writeChecked(_ data: Data?, account: String) throws {
        guard case .success(let service) = serviceResolution else { throw Failure.invalidProfile }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let data else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.operationFailed }
            return
        }
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.operationFailed }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw Failure.operationFailed }
    }

    static func get(account: String) -> String? {
        guard case .success(let service) = serviceResolution else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil или пустая строка → удалить запись.
    static func set(_ value: String?, account: String) {
        guard case .success(let service) = serviceResolution else { return }
        guard let value, !value.isEmpty else { delete(account: account); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        guard case .success(let service) = serviceResolution else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
