import CalopodDomain

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

public protocol CalendarProvider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }
}
