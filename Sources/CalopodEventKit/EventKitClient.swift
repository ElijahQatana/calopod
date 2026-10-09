import CalopodDomain
import CalopodProviders
import EventKit
import Foundation

/// Seam between `EventKitClient` and the real EventKit store, so tests can
/// substitute a fake gateway instead of touching the user's actual Calendar
/// data (or requiring Calendar permission at all).
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
    func managedEvents(
        calendarID: String,
        from start: Date,
        through end: Date
    ) -> [ManagedEventSnapshot]
    func createManagedEvent(
        calendarID: String,
        request: ManagedEventWriteRequest
    ) throws -> ManagedEventWriteResult
    func updateManagedEvent(
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?,
        request: ManagedEventWriteRequest
    ) throws -> ManagedEventWriteResult
    func deleteManagedEvent(
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?
    ) throws
    func changeNotifications() -> AsyncStream<Void>
}

/// Public entry point for talking to the local Calendar store. Every
/// operation except checking or requesting access first confirms full
/// access is actually granted, so a permission regression fails loudly with
/// `.permissionDenied` rather than silently returning partial or stale data.
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

    // Only prompts when the status is genuinely undecided; re-requesting
    // after a user has already denied or restricted access would just
    // re-show a system dialog macOS won't act on differently.
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

    public func managedEvents(
        calendarID: String,
        from start: Date,
        through end: Date
    ) throws -> [ManagedEventSnapshot] {
        try requireFullAccess()
        return gateway.managedEvents(calendarID: calendarID, from: start, through: end)
    }

    public func createManagedEvent(
        calendarID: String,
        request: ManagedEventWriteRequest
    ) throws -> ManagedEventWriteResult {
        try requireFullAccess()
        return try gateway.createManagedEvent(calendarID: calendarID, request: request)
    }

    public func updateManagedEvent(
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?,
        request: ManagedEventWriteRequest
    ) throws -> ManagedEventWriteResult {
        try requireFullAccess()
        return try gateway.updateManagedEvent(
            calendarID: calendarID,
            providerEventID: providerEventID,
            expectedVersion: expectedVersion,
            request: request
        )
    }

    public func deleteManagedEvent(
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?
    ) throws {
        try requireFullAccess()
        try gateway.deleteManagedEvent(
            calendarID: calendarID,
            providerEventID: providerEventID,
            expectedVersion: expectedVersion
        )
    }

    private func requireFullAccess() throws {
        guard gateway.authorizationStatus == .fullAccess else {
            throw ProviderFailure.permissionDenied
        }
    }
}

/// The real `EventKitGateway`, backed directly by `EKEventStore`.
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
                updatedAt: $0.lastModifiedDate,
                // The ownership marker is encoded into the URL field (see
                // `OwnershipMarkerCodec.markerURL`), so any event carrying
                // one of these URLs is Calopod's own mirror and must be
                // excluded from source ingestion.
                isManagedMirror: $0.url?.scheme == "calopod"
                    && $0.url?.host == "managed",
                location: $0.location ?? $0.structuredLocation?.title,
                notes: $0.notes,
                url: $0.url?.absoluteString,
                organizer: participant($0.organizer),
                attendees: ($0.attendees ?? []).compactMap(participant),
                responseMetadata: EventKitResponseNormalizer.response(
                    organizerIsCurrentUser: $0.organizer?.isCurrentUser == true,
                    participants: ($0.attendees ?? []).map {
                        EventKitResponseParticipant(isCurrentUser: $0.isCurrentUser,
                                                    status: $0.participantStatus)
                    },
                    sourceType: sourceType($0.calendar.source.sourceType)
                )
            )
        }
    }

    func managedEvents(
        calendarID: String,
        from start: Date,
        through end: Date
    ) -> [ManagedEventSnapshot] {
        guard let calendar = store.calendars(for: .event).first(where: {
            $0.calendarIdentifier == calendarID
        }) else { return [] }
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: [calendar]
        )
        return store.events(matching: predicate).map(managedSnapshot)
    }

    func createManagedEvent(
        calendarID: String,
        request: ManagedEventWriteRequest
    ) throws -> ManagedEventWriteResult {
        guard let calendar = writableCalendar(id: calendarID) else {
            throw ProviderFailure.permissionDenied
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        try EventKitManagedEventPresentation.apply(request, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        let providerEventID = event.eventIdentifier ?? event.calendarItemIdentifier
        return ManagedEventWriteResult(
            providerEventID: providerEventID,
            providerVersion: eventVersion(event)
        )
    }

    func updateManagedEvent(
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?,
        request: ManagedEventWriteRequest
    ) throws -> ManagedEventWriteResult {
        guard let calendar = writableCalendar(id: calendarID),
              let event = store.event(withIdentifier: providerEventID),
              event.calendar.calendarIdentifier == calendar.calendarIdentifier else {
            throw ProviderFailure.invalidResponse
        }
        // Optimistic concurrency: if the caller supplied the version it last
        // observed and the event has since changed, refuse the write (412)
        // rather than overwriting an edit sync hasn't seen yet.
        if let expectedVersion,
           eventVersion(event) != expectedVersion {
            throw ProviderFailure.httpStatus(412)
        }
        try EventKitManagedEventPresentation.apply(request, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        let savedID = event.eventIdentifier ?? event.calendarItemIdentifier
        return ManagedEventWriteResult(
            providerEventID: savedID,
            providerVersion: eventVersion(event)
        )
    }

    func deleteManagedEvent(
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?
    ) throws {
        guard let calendar = writableCalendar(id: calendarID),
              let event = store.event(withIdentifier: providerEventID),
              event.calendar.calendarIdentifier == calendar.calendarIdentifier else {
            throw ProviderFailure.invalidResponse
        }
        if let expectedVersion,
           eventVersion(event) != expectedVersion {
            throw ProviderFailure.httpStatus(412)
        }
        try store.remove(event, span: .thisEvent, commit: true)
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

    private func writableCalendar(id: String) -> EKCalendar? {
        store.calendars(for: .event).first {
            $0.calendarIdentifier == id && $0.allowsContentModifications
        }
    }

    /// Reads back a managed event's current state as a snapshot, decoding
    /// whatever ownership marker its URL carries. This is the data
    /// `ManagedTargetObserver` classifies — `managedSnapshot` itself makes no
    /// ownership judgment, it just reports what's on the calendar.
    private func managedSnapshot(_ event: EKEvent) -> ManagedEventSnapshot {
        let decoded: (ManagedEventMarkerStatus, ManagedEventProvenance?)
        if let url = event.url, url.scheme == "calopod", url.host == "managed" {
            if let marker = try? OwnershipMarkerCodec.marker(from: url) {
                decoded = (.parsed, marker)
            } else {
                decoded = (.invalid, nil)
            }
        } else {
            decoded = (.absent, nil)
        }
        let payload: DesiredEventPayload?
        if event.startDate < event.endDate {
            payload = DesiredEventPayload(
                startsAt: event.startDate,
                endsAt: event.endDate,
                isAllDay: event.isAllDay,
                availability: availability(event.availability).rawValue,
                title: event.title,
                isPrivate: nil,
                location: event.location,
                notes: event.notes
            )
        } else {
            payload = nil
        }
        return ManagedEventSnapshot(
            providerEventID: event.eventIdentifier ?? event.calendarItemIdentifier,
            providerVersion: eventVersion(event),
            payload: payload,
            markerStatus: decoded.0,
            provenance: decoded.1,
            createdAt: event.creationDate
        )
    }

    private func participant(_ value: EKParticipant?) -> EventParticipant? {
        guard let value else { return nil }
        return EventParticipant(
            name: value.name,
            emailAddress: participantEmail(value.url),
            status: participantStatus(value.participantStatus)
        )
    }

    // EKParticipant only exposes contact info as a `mailto:` URL, so this
    // pulls the address back out of it rather than relying on a separate
    // structured email field, which EventKit doesn't provide.
    private func participantEmail(_ url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        let encoded = String(url.absoluteString.dropFirst("mailto:".count))
            .split(separator: "?", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let value = encoded.removingPercentEncoding ?? encoded
        return value.isEmpty ? nil : value
    }

    private func participantStatus(_ status: EKParticipantStatus) -> String? {
        switch status {
        case .unknown: nil
        case .pending: "pending"
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .delegated: "delegated"
        case .completed: "completed"
        case .inProcess: "in-process"
        @unknown default: nil
        }
    }

    // EventKit doesn't always report a last-modified date for purely local
    // events, so this falls back to a stable per-item identity string —
    // still enough to detect that *some* write raced ahead, just not when.
    private func eventVersion(_ event: EKEvent) -> String {
        event.lastModifiedDate.map(eventIdentityDate)
            ?? "eventkit-local:\(event.calendarItemIdentifier)"
    }

    private func eventIdentityDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Maps a managed payload onto the EventKit fields Calopod can safely own.
/// Organizer and attendee fields remain untouched because EventKit exposes
/// them as read-only and native participant writes could send invitations.
@MainActor
enum EventKitManagedEventPresentation {
    static func apply(_ request: ManagedEventWriteRequest, to event: EKEvent) throws {
        event.title = request.payload.title ?? ""
        event.startDate = request.payload.startsAt
        event.endDate = request.payload.endsAt
        event.isAllDay = request.payload.isAllDay
        event.availability = availability(request.payload.availability)
        event.location = request.payload.location
        event.notes = request.payload.notes
        event.alarms = nil
        event.url = try OwnershipMarkerCodec.markerURL(request.provenance)
    }

    private static func availability(_ value: String) -> EKEventAvailability {
        switch value {
        case "free": .free
        case "tentative": .tentative
        case "unavailable", "out-of-office": .unavailable
        default: .busy
        }
    }
}

private final class ObserverToken: @unchecked Sendable {
    let value: any NSObjectProtocol

    init(_ value: any NSObjectProtocol) {
        self.value = value
    }
}
