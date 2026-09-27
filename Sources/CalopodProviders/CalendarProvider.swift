import CalopodDomain

/// What a provider backend supports, so callers can adapt behavior (for
/// example, whether a full re-scan is required) without hardcoding per-
/// provider special cases outside this one declaration.
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

/// The minimal identity every calendar backend (EventKit, Google, Microsoft,
/// ICS) exposes to the rest of the app, independent of how it actually talks
/// to its calendar.
public protocol CalendarProvider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }
}
