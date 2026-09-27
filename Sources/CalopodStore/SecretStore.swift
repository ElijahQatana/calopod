import Foundation

/// Opaque lookup key for one secret. Deliberately just an account string —
/// callers build it from the domain identifiers that make sense to them
/// (provider, connection ID, configuration ID) rather than the store
/// exposing its own ID scheme.
public struct SecretReference: Hashable, Sendable {
    public let account: String

    public init(account: String) {
        self.account = account
    }
}

/// Storage for anything that must live outside SQLite: OAuth tokens and
/// ownership signing keys. Kept as a narrow protocol so sync and provider
/// code can depend on it without depending on Keychain (or its test double)
/// directly.
public protocol SecretStore: Sendable {
    func save(_ value: Data, for reference: SecretReference) throws
    func value(for reference: SecretReference) throws -> Data?
    func removeValue(for reference: SecretReference) throws
}

public enum SecretStoreError: Error, Equatable {
    case keychainStatus(Int32)
    case unexpectedValue
}
