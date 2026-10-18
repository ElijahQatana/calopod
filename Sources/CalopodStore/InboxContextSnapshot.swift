import CalopodDomain
import Foundation
import GRDB

/// Source detail belongs to local inbox views, never Busy payloads or diagnostics.
public struct InboxContextSource: Codable, Equatable, Sendable {
    public let bindingID: String
    public let connectionID: String
    public let connectionLabel: String?
    public let calendarLabel: String?
    public let provider: String
    public let responseIdentityScope: ResponseIdentityScope
    public let coverage: InboxCoverage?
    public let healthStatus: String?
    public let staleSince: Date?
    public let providerColor: String?

    public init(
        bindingID: String, connectionID: String, connectionLabel: String? = nil,
        calendarLabel: String? = nil, provider: String,
        responseIdentityScope: ResponseIdentityScope = .unverified,
        coverage: InboxCoverage? = nil, healthStatus: String? = nil, staleSince: Date? = nil,
        providerColor: String? = nil
    ) {
        self.bindingID = bindingID
        self.connectionID = connectionID
        self.connectionLabel = connectionLabel
        self.calendarLabel = calendarLabel
        self.provider = provider
        self.responseIdentityScope = responseIdentityScope
        self.coverage = coverage
        self.healthStatus = healthStatus
        self.staleSince = staleSince
        self.providerColor = providerColor
    }
}

public struct InboxContextEvent: Codable, Equatable, Sendable {
    public let event: StoredNormalizedInstance
    public let observation: InboxObservation?
    public let isPresenceConfirmed: Bool

    public init(event: StoredNormalizedInstance, observation: InboxObservation? = nil, isPresenceConfirmed: Bool = true) {
        self.event = event
        self.observation = observation
        self.isPresenceConfirmed = isPresenceConfirmed
    }
}

/// One consistent local read. Caller-supplied duplicate evidence is explicit:
/// similarity of title/time or account type is never proof of shared identity.
public struct InboxContextSnapshot: Codable, Equatable, Sendable {
    public let sources: [InboxContextSource]
    public let events: [InboxContextEvent]
    public let unprovenDuplicateBindingIDs: Set<String>

    public init(
        sources: [InboxContextSource], events: [InboxContextEvent],
        unprovenDuplicateBindingIDs: Set<String> = []
    ) {
        self.sources = sources
        self.events = events
        self.unprovenDuplicateBindingIDs = unprovenDuplicateBindingIDs
    }
}

extension LocalStateRepository {
    /// Only active selected originals enter the model. Normalization already
    /// rejects marked mirrors; mapped copies are checked again on local reads.
    /// Known duplicate bindings can be excluded by a caller with proven identity.
    public func inboxContextSnapshot(
        knownDuplicateBindingIDs: Set<String> = [],
        unprovenDuplicateBindingIDs: Set<String> = []
    ) throws -> InboxContextSnapshot {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.id AS binding_id, b.connection_id, b.display_label AS calendar_label,
                       b.response_identity_scope, b.provider_color, c.display_label AS connection_label, c.provider,
                       h.status, h.stale_since, v.starts_at, v.ends_at, v.observed_at
                FROM calendar_bindings b JOIN connections c ON c.id = b.connection_id
                LEFT JOIN connection_health h ON h.connection_id = c.id
                LEFT JOIN inbox_coverage v ON v.connection_id = c.id AND v.calendar_binding_id = b.id
                WHERE b.is_selected = 1 AND c.is_enabled = 1 ORDER BY b.id
                """)
            let sources = rows.filter { !knownDuplicateBindingIDs.contains($0["binding_id"]) }.map { row in
                let start: Date? = row["starts_at"]
                let end: Date? = row["ends_at"]
                let observed: Date? = row["observed_at"]
                let coverage: InboxCoverage?
                if let start, let end, let observed {
                    coverage = InboxCoverage(startsAt: start, endsAt: end, observedAt: observed)
                } else { coverage = nil }
                return InboxContextSource(
                    bindingID: row["binding_id"], connectionID: row["connection_id"],
                    connectionLabel: row["connection_label"], calendarLabel: row["calendar_label"],
                    provider: row["provider"],
                    responseIdentityScope: ResponseIdentityScope(rawValue: row["response_identity_scope"]) ?? .unverified,
                    coverage: coverage, healthStatus: row["status"], staleSince: row["stale_since"],
                    providerColor: row["provider_color"]
                )
            }
            let bindingIDs = Set(sources.map(\.bindingID))
            var events = try Row.fetchAll(db, sql: """
                SELECT n.* FROM normalized_instances n
                WHERE n.is_cancelled = 0 AND NOT EXISTS (
                    SELECT 1 FROM mirror_mappings m JOIN arms a ON a.id = m.arm_id
                    WHERE a.target_binding_id = n.calendar_binding_id
                    AND m.provider_event_id = n.provider_event_id
                ) ORDER BY n.starts_at, n.source_key_hash
                """).filter { bindingIDs.contains($0["calendar_binding_id"]) }.compactMap { row -> InboxContextEvent? in
                let event = normalizedInstance(row)
                let observation = try loadInboxObservation(db, sourceKeyHash: event.sourceKeyHash)
                guard observation?.tombstone == nil else { return nil }
                // A retained observation may know about a move beyond the last
                // cache window. It is the newer local event evidence.
                return InboxContextEvent(event: observation?.event ?? event, observation: observation)
            }
            let activeKeys = Set(events.map(\.event.sourceKeyHash))
            let retainedKeys = try String.fetchAll(db, sql: "SELECT source_key_hash FROM inbox_observations ORDER BY source_key_hash")
            for key in retainedKeys where !activeKeys.contains(key) {
                guard let observation = try loadInboxObservation(db, sourceKeyHash: key), observation.tombstone == nil,
                      bindingIDs.contains(observation.event.calendarBindingID), !observation.event.isCancelled else { continue }
                let event = observation.event
                let mapped = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM mirror_mappings m JOIN arms a ON a.id = m.arm_id
                    WHERE a.target_binding_id = ? AND m.provider_event_id = ?)
                    """, arguments: [event.calendarBindingID, event.providerEventID]) ?? false
                guard !mapped else { continue }
                // A missing cache row is not deletion evidence. Retain the
                // last observation as uncertain context, never a proven pair.
                events.append(InboxContextEvent(event: event, observation: observation, isPresenceConfirmed: false))
            }
            events = try droppingUnmarkedCopies(events, db)
            events.sort { ($0.event.startsAt, $0.event.sourceKeyHash) < ($1.event.startsAt, $1.event.sourceKeyHash) }
            return InboxContextSnapshot(
                sources: sources, events: events,
                unprovenDuplicateBindingIDs: unprovenDuplicateBindingIDs.intersection(bindingIDs)
            )
        }
    }
}

/// A copy can come back without its marker or with a new id, so the mapping misses it: the
/// calendar read through a second connection, or an id that changed after a sync. It is still
/// taken for a copy of one of our events when an arm routes that event's calendar into the
/// copy's calendar (or the event has a stored copy), and the copy has the same time, the title
/// the copy would carry, no guests or the same guests, and no current-user evidence. An
/// invitation to the user always carries evidence, so a real one is never hidden by this.
private func droppingUnmarkedCopies(_ events: [InboxContextEvent], _ db: Database) throws -> [InboxContextEvent] {
    let arms = try Row.fetchAll(db, sql: """
        SELECT a.id, a.target_binding_id, a.rule_mode, s.calendar_binding_id AS source_binding_id
        FROM arms a JOIN arm_sources s ON s.arm_id = a.id WHERE a.is_enabled = 1
        """)
    let mapped = try Row.fetchAll(db, sql: """
        SELECT DISTINCT m.source_key_hash, a.rule_mode FROM mirror_mappings m JOIN arms a ON a.id = m.arm_id
        """)
    guard !arms.isEmpty || !mapped.isEmpty else { return events }
    let sourceKeys = Set(mapped.map { $0["source_key_hash"] as String })
    func isBusy(_ mode: String) -> Bool { mode == ArmRuleMode.busy.rawValue }
    func guests(_ event: StoredNormalizedInstance) -> Set<String> {
        Set(event.attendees.map { ($0.emailAddress ?? $0.name ?? "").lowercased() })
    }
    // Where each original's copy would be, and what it would look like.
    struct Candidate { let source: StoredNormalizedInstance; let title: String; let target: String? }
    var candidates: [Candidate] = []
    for item in events {
        let source = item.event
        for row in arms where (row["source_binding_id"] as String) == source.calendarBindingID {
            candidates.append(Candidate(
                source: source, title: isBusy(row["rule_mode"] as String) ? "Busy" : (source.title ?? ""),
                target: row["target_binding_id"] as String))
        }
        for row in mapped where (row["source_key_hash"] as String) == source.sourceKeyHash {
            candidates.append(Candidate(
                source: source, title: isBusy(row["rule_mode"] as String) ? "Busy" : (source.title ?? ""), target: nil))
        }
    }
    return events.filter { item in
        let event = item.event
        guard !sourceKeys.contains(event.sourceKeyHash), event.currentUserResponse.evidence == ResponseEvidence.none else { return true }
        return !candidates.contains { candidate in
            let source = candidate.source
            guard source.sourceKeyHash != event.sourceKeyHash, source.calendarBindingID != event.calendarBindingID,
                  candidate.target.map({ $0 == event.calendarBindingID }) ?? true,
                  source.startsAt == event.startsAt, source.endsAt == event.endsAt, source.isAllDay == event.isAllDay,
                  candidate.title == (event.title ?? "") else { return false }
            let mine = guests(event)
            return mine.isEmpty || mine == guests(source)
        }
    }
}
