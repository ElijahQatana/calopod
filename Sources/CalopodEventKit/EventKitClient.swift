import CalopodDomain
import CalopodProviders
import EventKit
import Foundation

/// Seam over the real EventKit store so tests can use a fake instead of the user's calendars.
public protocol EventKitGateway: Actor {
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

/// Entry point for the local Calendar store. Every call except the access check confirms full
/// access first, so a permission loss fails loudly.
public final class EventKitClient: Sendable {
    private let gateway: any EventKitGateway

    public init(gateway: any EventKitGateway) {
        self.gateway = gateway
    }

    public convenience init() {
        self.init(gateway: LiveEventKitGateway())
    }

    public var authorizationStatus: EventKitAccessStatus {
        get async { await gateway.authorizationStatus }
    }

    // Only prompt when the status is undecided; macOS ignores a second request after a denial.
    public func requestFullAccess() async throws -> EventKitAccessStatus {
        if await gateway.authorizationStatus == .notDetermined {
            try await gateway.requestFullAccess()
        }
        return await gateway.authorizationStatus
    }

    public func calendars() async throws -> [EventKitCalendarSnapshot] {
        try await requireFullAccess()
        return await gateway.calendars()
    }

    public func events(
        calendarIDs: [String],
        from start: Date,
        through end: Date
    ) async throws -> [ProviderEvent] {
        try await requireFullAccess()
        guard !calendarIDs.isEmpty, start < end else {
            throw ProviderFailure.invalidResponse
        }
        return await gateway.events(calendarIDs: calendarIDs, from: start, through: end)
    }

    public func changeNotifications() async -> AsyncStream<Void> {
        await gateway.changeNotifications()
    }

    public func managedEvents(
        calendarID: String,
        from start: Date,
        through end: Date
    ) async throws -> [ManagedEventSnapshot] {
        try await requireFullAccess()
        return await gateway.managedEvents(calendarID: calendarID, from: start, through: end)
    }

    public func createManagedEvent(
        calendarID: String,
        request: ManagedEventWriteRequest
    ) async throws -> ManagedEventWriteResult {
        try await requireFullAccess()
        return try await gateway.createManagedEvent(calendarID: calendarID, request: request)
    }

    public func updateManagedEvent(
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?,
        request: ManagedEventWriteRequest
    ) async throws -> ManagedEventWriteResult {
        try await requireFullAccess()
        return try await gateway.updateManagedEvent(
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
    ) async throws {
        try await requireFullAccess()
        try await gateway.deleteManagedEvent(
            calendarID: calendarID,
            providerEventID: providerEventID,
            expectedVersion: expectedVersion
        )
    }

    private func requireFullAccess() async throws {
        guard await gateway.authorizationStatus == .fullAccess else {
            throw ProviderFailure.permissionDenied
        }
    }
}

/// The real `EventKitGateway`, backed directly by `EKEventStore`.
private actor LiveEventKitGateway: EventKitGateway {
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
        // Older toolchains reject sending the store into the async overload, so use the callback
        // form.
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
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
                end: EventKitAllDayDates.exclusiveEnd($0.endDate, isAllDay: $0.isAllDay, in: .current),
                isAllDay: $0.isAllDay,
                availability: availability($0.availability),
                isCancelled: $0.status == .canceled,
                isPrivate: false,
                title: $0.title,
                updatedAt: $0.lastModifiedDate,
                // The ownership marker is stored in the URL field, so an event with one is
                // Calopod's own mirror and is excluded from sources.
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
                ),
                // Floating all-day dates are returned in the Mac's zone.
                timeZoneIdentifier: $0.isAllDay ? TimeZone.current.identifier : nil
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
        // If the event changed since the caller last saw it, refuse the write (412) instead of
        // overwriting.
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
        let store = store
        return AsyncStream { continuation in
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

    /// Reads a managed event back as a snapshot. It reports what is there and makes no ownership
    /// judgment.
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
                endsAt: EventKitAllDayDates.exclusiveEnd(event.endDate, isAllDay: event.isAllDay, in: .current) ?? event.endDate,
                isAllDay: event.isAllDay,
                availability: availability(event.availability).rawValue,
                title: event.title,
                isPrivate: nil,
                location: event.location,
                notes: event.notes,
                timeZoneIdentifier: event.isAllDay ? TimeZone.current.identifier : nil
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

    // EKParticipant only exposes a `mailto:` URL, so the address is taken from that.
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

    // Local events may have no modification date, so fall back to a per-item string. That still
    // shows a write happened, just not when.
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
enum EventKitManagedEventPresentation {
    static func apply(_ request: ManagedEventWriteRequest, to event: EKEvent) throws {
        event.title = request.payload.title ?? ""
        event.isAllDay = request.payload.isAllDay
        let (startDate, endDate) = dates(for: request.payload, in: .current)
        event.startDate = startDate
        event.endDate = endDate
        event.availability = availability(request.payload.availability)
        event.location = request.payload.location
        event.notes = request.payload.notes
        event.alarms = nil
        event.url = try OwnershipMarkerCodec.markerURL(request.provenance)
    }

    /// EventKit includes the end day; shared payloads use an exclusive end.
    static func dates(for payload: DesiredEventPayload, in zone: TimeZone) -> (Date, Date) {
        guard payload.isAllDay else { return (payload.startsAt, payload.endsAt) }
        let days = AllDayDate.days(
            startsAt: payload.startsAt,
            endsAt: payload.endsAt,
            timeZoneIdentifier: payload.timeZoneIdentifier
        )
        return (
            AllDayDate.midnight(of: days.start, in: zone) ?? payload.startsAt,
            (AllDayDate.midnight(of: days.end, in: zone) ?? payload.endsAt).addingTimeInterval(-1)
        )
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

enum EventKitAllDayDates {
    static func exclusiveEnd(_ end: Date?, isAllDay: Bool, in zone: TimeZone) -> Date? {
        guard isAllDay, let end else { return end }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.hour, .minute, .second], from: end)
        guard components.hour == 23, components.minute == 59, components.second == 59 else { return end }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
    }
}

private final class ObserverToken: @unchecked Sendable {
    let value: any NSObjectProtocol

    init(_ value: any NSObjectProtocol) {
        self.value = value
    }
}
