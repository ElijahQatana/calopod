import CalopodStore
import Foundation

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretReference: Data] = [:]

    public init() {}

    public func save(_ value: Data, for reference: SecretReference) throws {
        lock.withLock { values[reference] = value }
    }

    public func value(for reference: SecretReference) throws -> Data? {
        lock.withLock { values[reference] }
    }

    public func removeValue(for reference: SecretReference) throws {
        lock.withLock { values[reference] = nil }
    }
}
