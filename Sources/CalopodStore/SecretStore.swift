import Foundation

/// Opaque lookup key for one secret. Callers build it from their own identifiers.
public struct SecretReference: Hashable, Sendable {
    public let account: String

    public init(account: String) {
        self.account = account
    }
}

/// Storage for what must stay outside SQLite (tokens, signing keys), behind a protocol so code
/// doesn't depend on the Keychain.
public protocol SecretStore: Sendable {
    func save(_ value: Data, for reference: SecretReference) throws
    func value(for reference: SecretReference) throws -> Data?
    func removeValue(for reference: SecretReference) throws
}

public enum SecretStoreError: Error, Equatable {
    case keychainStatus(Int32)
    case unexpectedValue
}
