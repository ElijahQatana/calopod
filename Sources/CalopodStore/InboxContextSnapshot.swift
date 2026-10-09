import CalopodDomain
import Foundation
import GRDB

/// Source detail belongs to local inbox views, never Busy payloads or diagnostics.
public struct InboxContextSource: Equatable, Sendable {
    public let bindingID: String
    public let connectionID: String
    public let connectionLabel: String?
    public let calendarLabel: String?
    public let provider: String
    public let responseIdentityScope: ResponseIdentityScope
    public let coverage: InboxCoverage?
    public let healthStatus: String?
    public let staleSince: Date?

    public init(
        bindingID: String, connectionID: String, connectionLabel: String? = nil,
        calendarLabel: String? = nil, provider: String,
        responseIdentityScope: ResponseIdentityScope = .unverified,
        coverage: InboxCoverage? = nil, healthStatus: String? = nil, staleSince: Date? = nil
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
    }
}

public struct InboxContextEvent: Equatable, Sendable {
    public let event: StoredNormalizedInstance
    public let observation: InboxObservation?

    public init(event: StoredNormalizedInstance, observation: InboxObservation? = nil) {
        self.event = event
        self.observation = observation
    }
}

/// One consistent local read. Caller-supplied duplicate evidence is explicit:
/// similarity of title/time or account type is never proof of shared identity.
public struct InboxContextSnapshot: Equatable, Sendable {
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
                       b.response_identity_scope, c.display_label AS connection_label, c.provider,
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
                    coverage: coverage, healthStatus: row["status"], staleSince: row["stale_since"]
                )
            }
            let bindingIDs = Set(sources.map(\.bindingID))
            let events = try Row.fetchAll(db, sql: """
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
            return InboxContextSnapshot(
                sources: sources, events: events,
                unprovenDuplicateBindingIDs: unprovenDuplicateBindingIDs.intersection(bindingIDs)
            )
        }
    }
}
