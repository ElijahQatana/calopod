import CalopodDomain
import CalopodProviders
import CalopodStore
import CryptoKit
import Foundation

/// Manages the single EventKit Connection ("Calendars on this Mac") and its
/// calendar bindings. Unlike Google or Microsoft, there is exactly one
/// EventKit connection per device, so this never has to route between
/// multiple accounts on the same provider.
public struct EventKitConnectionService: Sendable {
    private static let provider = ProviderKind.eventKit.rawValue
    private let state: LocalStateRepository

    public init(state: LocalStateRepository) {
        self.state = state
    }

    /// Creates the EventKit connection on first use, or reuses the existing
    /// one — calling this again after Calendars are already connected just
    /// refreshes the calendar list rather than creating a duplicate
    /// connection.
    public func connect(
        calendars: [EventKitCalendarSnapshot],
        configurationID: String = "default",
        now: Date = Date()
    ) throws -> StoredConnection {
        let existing = try state.connections(provider: Self.provider).first
        let connection = existing ?? StoredConnection(
            id: "eventkit-device",
            configurationID: configurationID,
            provider: Self.provider,
            displayLabel: "Calendars on this Mac",
            isEnabled: true
        )
        try state.saveConnection(connection, now: now)
        try replaceCalendars(calendars, connectionID: connection.id, now: now)
        return connection
    }

    public func refreshCalendars(
        _ calendars: [EventKitCalendarSnapshot],
        connectionID: String,
        now: Date = Date()
    ) throws -> [StoredCalendarBinding] {
        try replaceCalendars(calendars, connectionID: connectionID, now: now)
        return try state.calendarBindings(connectionID: connectionID)
    }

    public func disconnect(connectionID: String) throws {
        try state.removeConnection(id: connectionID)
    }

    private func replaceCalendars(
        _ calendars: [EventKitCalendarSnapshot],
        connectionID: String,
        now: Date
    ) throws {
        let bindings = calendars.map {
            StoredCalendarBinding(
                id: stableBindingID(
                    connectionID: connectionID,
                    sourceID: $0.sourceID,
                    calendarID: $0.id
                ),
                connectionID: connectionID,
                providerCalendarID: $0.id,
                displayLabel: $0.title,
                isSelected: false,
                isReadOnly: !$0.allowsContentModifications,
                providerSourceID: $0.sourceID,
                providerSourceType: $0.sourceType,
                providerSourceLabel: $0.sourceTitle
            )
        }
        try state.replaceCalendarBindings(connectionID: connectionID, bindings: bindings, now: now)
    }

    /// Derives a calendar binding's ID from its identity rather than
    /// generating a random one, so re-connecting or refreshing the same
    /// EventKit calendar always maps to the same binding row instead of
    /// creating a duplicate.
    private func stableBindingID(
        connectionID: String,
        sourceID: String,
        calendarID: String
    ) -> String {
        let input = Data("eventkit-binding-v1|\(connectionID)|\(sourceID)|\(calendarID)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}
