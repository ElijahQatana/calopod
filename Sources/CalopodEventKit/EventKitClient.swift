import CalopodProviders
import EventKit
import Foundation

@MainActor
public protocol EventKitGateway: AnyObject {
    var authorizationStatus: EventKitAccessStatus { get }
    func requestFullAccess() async throws
    func calendars() -> [EventKitCalendarSnapshot]
    func events(
        calendarIDs: [String],
        from start: Date,
        through end: Date
    ) -> [ProviderEvent]
    func changeNotifications() -> AsyncStream<Void>
}

@MainActor
public final class EventKitClient {
    private let gateway: any EventKitGateway

    public init(gateway: any EventKitGateway) {
        self.gateway = gateway
    }

    public convenience init() {
        self.init(gateway: LiveEventKitGateway())
    }

    public var authorizationStatus: EventKitAccessStatus {
        gateway.authorizationStatus
    }

    public func requestFullAccess() async throws -> EventKitAccessStatus {
        if gateway.authorizationStatus == .notDetermined {
            try await gateway.requestFullAccess()
        }
        return gateway.authorizationStatus
    }

    public func calendars() throws -> [EventKitCalendarSnapshot] {
        try requireFullAccess()
        return gateway.calendars()
    }

    public func events(
        calendarIDs: [String],
        from start: Date,
        through end: Date
    ) throws -> [ProviderEvent] {
        try requireFullAccess()
        guard !calendarIDs.isEmpty, start < end else {
            throw ProviderFailure.invalidResponse
        }
        return gateway.events(calendarIDs: calendarIDs, from: start, through: end)
    }

    public func changeNotifications() -> AsyncStream<Void> {
        gateway.changeNotifications()
    }

    private func requireFullAccess() throws {
        guard gateway.authorizationStatus == .fullAccess else {
            throw ProviderFailure.permissionDenied
        }
    }
}

@MainActor
private final class LiveEventKitGateway: EventKitGateway {
    private let store = EKEventStore()

    var authorizationStatus: EventKitAccessStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess, .authorized: .fullAccess
        case .writeOnly: .writeOnly
        @unknown default: .unknown
        }
    }

    func requestFullAccess() async throws {
        _ = try await store.requestFullAccessToEvents()
    }

    func calendars() -> [EventKitCalendarSnapshot] {
        store.calendars(for: .event).map {
            EventKitCalendarSnapshot(
                id: $0.calendarIdentifier,
                title: $0.title,
                sourceID: $0.source.sourceIdentifier,
                sourceTitle: $0.source.title,
                sourceType: sourceType($0.source.sourceType),
                allowsContentModifications: $0.allowsContentModifications
            )
        }
    }

    func events(
        calendarIDs: [String],
        from start: Date,
        through end: Date
    ) -> [ProviderEvent] {
        let selected = store.calendars(for: .event).filter {
            calendarIDs.contains($0.calendarIdentifier)
        }
        guard !selected.isEmpty else { return [] }
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: selected
        )
        return store.events(matching: predicate).map {
            ProviderEvent(
                provider: "eventkit",
                connectionID: "eventkit-device",
                calendarID: $0.calendar.calendarIdentifier,
                eventID: $0.eventIdentifier ?? $0.calendarItemIdentifier,
                seriesID: $0.hasRecurrenceRules ? $0.calendarItemExternalIdentifier : nil,
                originalStart: $0.occurrenceDate.map(eventIdentityDate),
                start: $0.startDate,
                end: $0.endDate,
                isAllDay: $0.isAllDay,
                availability: availability($0.availability),
                isCancelled: $0.status == .canceled,
                isPrivate: false,
                title: $0.title,
                updatedAt: $0.lastModifiedDate
            )
        }
    }

    func changeNotifications() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = ObserverToken(
                NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: store,
                queue: .main
            ) { _ in
                continuation.yield()
                }
            )
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token.value)
            }
        }
    }

    private func sourceType(_ type: EKSourceType) -> String {
        switch type {
        case .local: "local"
        case .exchange: "exchange"
        case .calDAV: "caldav"
        case .mobileMe: "mobileme"
        case .subscribed: "subscribed"
        case .birthdays: "birthdays"
        @unknown default: "unknown"
        }
    }

    private func availability(_ value: EKEventAvailability) -> ProviderAvailability {
        switch value {
        case .free: .free
        case .tentative: .tentative
        case .busy: .busy
        case .unavailable: .unavailable
        case .notSupported: .busy
        @unknown default: .busy
        }
    }

    private func eventIdentityDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private final class ObserverToken: @unchecked Sendable {
    let value: any NSObjectProtocol

    init(_ value: any NSObjectProtocol) {
        self.value = value
    }
}
