import Foundation
import Security

/// The Keychain-backed `SecretStore`. Items use `AfterFirstUnlockThisDeviceOnly`: readable after
/// the first unlock since boot, never synced.
public struct KeychainSecretStore: SecretStore, Sendable {
    private let service: String
    private let allowsPrompt: Bool

    /// `allowsPrompt` false makes a read fail instead of letting macOS ask for access, so a check
    /// the person did not start cannot raise a keychain prompt.
    public init(service: String = "com.calopod.credentials", allowsPrompt: Bool = true) {
        self.service = service
        self.allowsPrompt = allowsPrompt
    }

    // Keychain has no upsert, so try an update first and add only if the item is missing. This
    // avoids a duplicate-item error on every later write.
    public func save(_ value: Data, for reference: SecretReference) throws {
        let query = baseQuery(for: reference)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw SecretStoreError.keychainStatus(updateStatus)
        }

        var addition = query
        attributes.forEach { addition[$0.key] = $0.value }
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecretStoreError.keychainStatus(addStatus)
        }
    }

    public func value(for reference: SecretReference) throws -> Data? {
        var query = baseQuery(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsPrompt { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw SecretStoreError.keychainStatus(status)
        }

        guard let data = result as? Data else {
            throw SecretStoreError.unexpectedValue
        }

        return data
    }

    public func removeValue(for reference: SecretReference) throws {
        let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychainStatus(status)
        }
    }

    private func baseQuery(for reference: SecretReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.account,
        ]
    }
}
