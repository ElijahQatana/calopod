import CalopodDomain
import CalopodProviders
import CalopodStore
import CryptoKit
import Foundation

public struct EventCacheResult: Equatable, Sendable {
    public let storedCount: Int
    public let cancelledCount: Int
    public let discardedCount: Int
    public let refreshMode: ProviderRefreshMode

    public init(
        storedCount: Int,
        cancelledCount: Int,
        discardedCount: Int,
        refreshMode: ProviderRefreshMode
    ) {
        self.storedCount = storedCount
        self.cancelledCount = cancelledCount
        self.discardedCount = discardedCount
        self.refreshMode = refreshMode
    }
}

public struct EventCache: Sendable {
    private let repository: LocalStateRepository

    public init(repository: LocalStateRepository) {
        self.repository = repository
    }

    @discardableResult
    public func apply(
        _ page: ProviderEventPage,
        connection: StoredConnection,
        calendar: StoredCalendarBinding,
        from start: Date,
        through end: Date,
        now: Date = Date()
    ) throws -> EventCacheResult {
        let normalized = EventNormalizer.normalize(
            page.events,
            connection: connection,
            calendar: calendar,
            from: start,
            through: end
        )
        let cursors = page.cursorUpdates.map {
            StoredCursorUpdate(
                scopeKey: $0.scopeKey,
                value: $0.value,
                scopeStart: $0.scopeStart,
                scopeEnd: $0.scopeEnd
            )
        }
        try repository.applyEventRefresh(
            connectionID: connection.id,
            calendarBindingID: calendar.id,
            windowStart: start,
            windowEnd: end,
            instances: normalized.instances,
            cancelledSourceKeyHashes: normalized.cancelledSourceKeyHashes,
            isFullRefresh: page.refreshMode == .full,
            cursorUpdates: cursors,
            now: now
        )
        return EventCacheResult(
            storedCount: normalized.instances.count,
            cancelledCount: normalized.cancelledSourceKeyHashes.count,
            discardedCount: normalized.discardedCount,
            refreshMode: page.refreshMode
        )
    }
}

public enum EventNormalizer {
    public struct Result: Equatable, Sendable {
        public let instances: [StoredNormalizedInstance]
        public let cancelledSourceKeyHashes: [String]
        public let discardedCount: Int
    }

    public static func normalize(
        _ events: [ProviderEvent],
        connection: StoredConnection,
        calendar: StoredCalendarBinding,
        from windowStart: Date,
        through windowEnd: Date
    ) -> Result {
        var instances: [StoredNormalizedInstance] = []
        var cancellations: [String] = []
        var discardedCount = 0

        for event in events {
            guard !event.isManagedMirror else {
                discardedCount += 1
                continue
            }
            guard event.provider == connection.provider,
                  event.connectionID == connection.id,
                  event.calendarID == calendar.providerCalendarID,
                  !event.eventID.isEmpty else {
                discardedCount += 1
                continue
            }
            let sourceKeyHash = digest(
                fields: [event.provider, connection.id, calendar.id, event.eventID]
            )
            if event.isCancelled {
                cancellations.append(sourceKeyHash)
                continue
            }
            guard let startsAt = event.start,
                  let endsAt = event.end,
                  startsAt < endsAt,
                  endsAt > windowStart,
                  startsAt < windowEnd else {
                discardedCount += 1
                continue
            }

            let recurrenceID = event.originalStart ?? event.seriesID
            let fingerprint = digest(
                fields: [
                    event.provider,
                    connection.id,
                    calendar.id,
                    event.eventID,
                    event.seriesID ?? "",
                    event.originalStart ?? "",
                    dateIdentity(startsAt),
                    dateIdentity(endsAt),
                    event.isAllDay ? "1" : "0",
                    event.availability.rawValue,
                    event.isPrivate ? "1" : "0",
                    event.title ?? "",
                    event.location ?? "",
                    event.notes ?? "",
                    event.url ?? "",
                    participantIdentity(event.organizer),
                    event.attendees.map { participantIdentity($0) }.sorted().joined(separator: "\n"),
                ]
            )
            instances.append(
                StoredNormalizedInstance(
                    sourceKeyHash: sourceKeyHash,
                    connectionID: connection.id,
                    calendarBindingID: calendar.id,
                    providerEventID: event.eventID,
                    recurrenceID: recurrenceID,
                    startsAt: startsAt,
                    endsAt: endsAt,
                    isAllDay: event.isAllDay,
                    availability: event.availability.rawValue,
                    isCancelled: false,
                    isPrivate: event.isPrivate,
                    title: event.title,
                    contentFingerprint: fingerprint,
                    providerUpdatedAt: event.updatedAt,
                    location: event.location,
                    notes: event.notes,
                    url: event.url,
                    organizer: event.organizer,
                    attendees: event.attendees
                )
            )
        }

        return Result(
            instances: instances.sorted {
                ($0.startsAt, $0.endsAt, $0.sourceKeyHash)
                    < ($1.startsAt, $1.endsAt, $1.sourceKeyHash)
            },
            cancelledSourceKeyHashes: cancellations.sorted(),
            discardedCount: discardedCount
        )
    }

    private static func dateIdentity(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate.bitPattern)
    }

    private static func participantIdentity(_ participant: EventParticipant?) -> String {
        guard let participant else { return "" }
        return [participant.name ?? "", participant.emailAddress ?? "", participant.status ?? ""]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    private static func digest(fields: [String]) -> String {
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
