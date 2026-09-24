import CalopodDomain

public struct ProviderCursor: Equatable, Sendable {
    public let connectionID: String
    public let calendarBindingID: String
    public let value: String

    public init(connectionID: String, calendarBindingID: String, value: String) {
        self.connectionID = connectionID
        self.calendarBindingID = calendarBindingID
        self.value = value
    }
}

public protocol SyncStateStore: Sendable {
    func cursor(connectionID: String, calendarBindingID: String) async throws -> ProviderCursor?
    func save(cursor: ProviderCursor) async throws
}
