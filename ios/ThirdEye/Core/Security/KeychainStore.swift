import Foundation
import Security

/// Stores secrets (AI API keys) as synchronizable generic-password items.
///
/// - Synchronizable items travel iPhone ↔ iPad through end-to-end-encrypted iCloud Keychain.
/// - `kSecAttrAccessibleWhenUnlocked`: readable only while the device is unlocked.
/// - Secrets never touch UserDefaults, SwiftData, CloudKit, logs or crash reports.
nonisolated struct KeychainStore: Sendable {
    nonisolated enum KeychainError: LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
                return "Keychain error \(status): \(message)"
            case .invalidData:
                return "The stored key could not be read."
            }
        }
    }

    let service: String
    let synchronizable: Bool

    init(service: String = "com.jondhale.thirdeye.secrets", synchronizable: Bool = true) {
        self.service = service
        self.synchronizable = synchronizable
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // `Any` so reads/deletes find the item whether or not it is synchronizable.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.invalidData }
        // Delete-then-add keeps the code simple and guarantees the accessibility class is applied.
        try? delete(account)
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String: data,
        ]
        attributes[kSecAttrLabel as String] = "Third Eye \(account)"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func get(_ account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func contains(_ account: String) -> Bool {
        (try? get(account)) != nil
    }
}

/// Shows only the edges of a secret, e.g. `sk-ant-…9f2c`.
nonisolated func maskedSecret(_ secret: String) -> String {
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 10 else { return String(repeating: "•", count: max(trimmed.count, 4)) }
    return "\(trimmed.prefix(6))…\(trimmed.suffix(4))"
}
