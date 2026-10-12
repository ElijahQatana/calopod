import CalopodDomain

/// What a provider supports, so callers can adapt without per-provider special cases.
public struct ProviderCapabilities: Equatable, Sendable {
    public let canRead: Bool
    public let canWrite: Bool
    public let supportsIncrementalChanges: Bool

    public init(
        canRead: Bool,
        canWrite: Bool,
        supportsIncrementalChanges: Bool
    ) {
        self.canRead = canRead
        self.canWrite = canWrite
        self.supportsIncrementalChanges = supportsIncrementalChanges
    }
}

/// The minimal identity every calendar backend exposes.
public protocol CalendarProvider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }
}
