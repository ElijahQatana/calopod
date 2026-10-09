import CalopodDomain
import CalopodProviders
import CalopodStore
import CryptoKit
import Foundation

public struct EventCacheResult: Equatable, Sendable {
    public let storedCount: Int
    public let cancelledCount: Int
    public let discardedCount: Int
    public let ingestion: EventIngestionSummary
    public let refreshMode: ProviderRefreshMode

    public init(
        storedCount: Int,
        cancelledCount: Int,
        discardedCount: Int,
        refreshMode: ProviderRefreshMode,
        ingestion: EventIngestionSummary = EventIngestionSummary()
    ) {
        self.storedCount = storedCount
        self.cancelledCount = cancelledCount
        self.discardedCount = discardedCount
        self.refreshMode = refreshMode
        self.ingestion = ingestion
    }
}

/// Applies one page of provider events to the local normalized-event store.
/// This is the boundary between "whatever a provider just returned" and the
/// stable, provider-agnostic `StoredNormalizedInstance` shape the rest of
/// the sync engine (planning, Availability) actually works with.
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
            through: end,
            excludedEventIDs: try repository.managedTargetEventIDs(calendarBindingID: calendar.id)
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
            cancelledSourceKeyHashes: normalized.cancelledSourceKeyHashes + normalized.excludedSourceKeyHashes,
            isFullRefresh: page.refreshMode == .full,
            cursorUpdates: cursors,
            now: now
        )
        return EventCacheResult(
            storedCount: normalized.instances.count,
            cancelledCount: normalized.cancelledSourceKeyHashes.count,
            discardedCount: normalized.discardedCount,
            refreshMode: page.refreshMode,
            ingestion: normalized.ingestion
        )
    }
}

/// Converts raw provider events into normalized instances keyed by a stable
/// hash of provider, connection, calendar, and event ID. EventKit recurring
/// instances also include their original occurrence date because a series
/// may share one event ID. Moving an occurrence preserves that identity.
public enum EventNormalizer {
    public struct Result: Equatable, Sendable {
        public let instances: [StoredNormalizedInstance]
        public let cancelledSourceKeyHashes: [String]
        public let discardedCount: Int
        public let ingestion: EventIngestionSummary
        public let excludedSourceKeyHashes: [String]
    }

    public static func normalize(
        _ events: [ProviderEvent],
        connection: StoredConnection,
        calendar: StoredCalendarBinding,
        from windowStart: Date,
        through windowEnd: Date,
        excludedEventIDs: Set<String> = []
    ) -> Result {
        var instances: [StoredNormalizedInstance] = []
        var cancellations: [String] = []
        var excluded: [String] = []
        var ingestion = EventIngestionSummary()

        for event in events {
            // Defends against a page that somehow contains events for the
            // wrong connection or calendar (a provider bug, or a stale
            // cache); silently accepting them would attribute events to the
            // wrong source.
            guard event.provider == connection.provider,
                  event.connectionID == connection.id,
                  event.calendarID == calendar.providerCalendarID,
                  !event.eventID.isEmpty else {
                ingestion.invalidIdentityCount += 1
                continue
            }
            let sourceKeyHash = sourceKeyHash(
                provider: event.provider, connectionID: connection.id,
                calendarBindingID: calendar.id, eventID: event.eventID,
                originalStart: event.originalStart
            )
            // Copies never become sources, including mapped copies whose
            // marker was removed. Evict any previous cached source instance
            // on incremental refresh as well as on a full refresh.
            if event.isManagedMirror || excludedEventIDs.contains(event.eventID) {
                excluded.append(sourceKeyHash)
                if event.isManagedMirror {
                    ingestion.excludedMarkedCopyCount += 1
                } else {
                    ingestion.excludedMappedCopyCount += 1
                }
                continue
            }
            if event.isCancelled {
                cancellations.append(sourceKeyHash)
                continue
            }
            // A malformed timespan or one that falls entirely outside the
            // requested window is dropped rather than stored, keeping every
            // downstream pass bounded to the window it asked for.
            guard let startsAt = event.start,
                  let endsAt = event.end,
                  startsAt < endsAt else {
                ingestion.invalidTimespanCount += 1
                continue
            }
            guard endsAt > windowStart, startsAt < windowEnd else {
                ingestion.outOfRangeCount += 1
                continue
            }

            let recurrenceID = event.originalStart ?? event.seriesID
            // Fingerprints the full event content (not just identity) so a
            // later refresh can tell a real edit apart from an unchanged
            // event returned again by the provider.
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
                    attendees: event.attendees,
                    currentUserResponse: event.currentUserResponse
                )
            )
        }

        return Result(
            instances: instances.sorted {
                ($0.startsAt, $0.endsAt, $0.sourceKeyHash)
                    < ($1.startsAt, $1.endsAt, $1.sourceKeyHash)
            },
            cancelledSourceKeyHashes: cancellations.sorted(),
            discardedCount: ingestion.discardedCount,
            ingestion: ingestion,
            excludedSourceKeyHashes: excluded.sorted()
        )
    }

    /// Omitting the occurrence reproduces the legacy EventKit identity for review only.
    public static func sourceKeyHash(
        provider: String, connectionID: String, calendarBindingID: String,
        eventID: String, originalStart: String? = nil
    ) -> String {
        var fields = [provider, connectionID, calendarBindingID, eventID]
        if provider == "eventkit", let originalStart, !originalStart.isEmpty {
            fields.append(originalStart)
        }
        return digest(fields: fields)
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
