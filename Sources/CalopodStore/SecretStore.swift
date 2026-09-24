import Foundation

public struct SecretReference: Hashable, Sendable {
    public let account: String

    public init(account: String) {
        self.account = account
    }
}

public protocol SecretStore: Sendable {
    func save(_ value: Data, for reference: SecretReference) throws
    func value(for reference: SecretReference) throws -> Data?
    func removeValue(for reference: SecretReference) throws
}

public enum SecretStoreError: Error, Equatable {
    case keychainStatus(Int32)
    case unexpectedValue
}
