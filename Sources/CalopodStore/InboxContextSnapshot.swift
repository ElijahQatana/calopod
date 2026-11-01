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
    public let snoozes: [String: InboxSnooze]

    public init(
        sources: [InboxContextSource], events: [InboxContextEvent],
        unprovenDuplicateBindingIDs: Set<String> = [], snoozes: [String: InboxSnooze] = [:]
    ) {
        self.sources = sources
        self.events = events
        self.unprovenDuplicateBindingIDs = unprovenDuplicateBindingIDs
        self.snoozes = snoozes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sources = try values.decode([InboxContextSource].self, forKey: .sources)
        events = try values.decode([InboxContextEvent].self, forKey: .events)
        unprovenDuplicateBindingIDs = try values.decode(Set<String>.self, forKey: .unprovenDuplicateBindingIDs)
        // Reviews saved before snoozing have none.
        snoozes = try values.decodeIfPresent([String: InboxSnooze].self, forKey: .snoozes) ?? [:]
    }
}

extension LocalStateRepository {
    /// Only active selected originals enter the model. Normalization already
    /// rejects marked mirrors; mapped copies are checked again on local reads.
    /// Known duplicate bindings can be excluded by a caller with proven identity.
    public func inboxContextSnapshot(
        knownDuplicateBindingIDs: Set<String> = [],
        unprovenDuplicateBindingIDs: Set<String> = [],
        includingCopies: Bool = false
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
                    AND (m.provider_event_id = n.provider_event_id
                         OR (n.provider_external_id IS NOT NULL AND m.provider_external_id = n.provider_external_id))
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
                    WHERE a.target_binding_id = ?
                    AND (m.provider_event_id = ? OR (? IS NOT NULL AND m.provider_external_id = ?)))
                    """, arguments: [event.calendarBindingID, event.providerEventID,
                                     event.providerExternalID, event.providerExternalID]) ?? false
                guard !mapped else { continue }
                // A missing cache row is not deletion evidence. Retain the
                // last observation as uncertain context, never a proven pair.
                events.append(InboxContextEvent(event: event, observation: observation, isPresenceConfirmed: false))
            }
            if !includingCopies { events = try droppingUnmarkedCopies(events, db) }
            events.sort { ($0.event.startsAt, $0.event.sourceKeyHash) < ($1.event.startsAt, $1.event.sourceKeyHash) }
            return InboxContextSnapshot(
                sources: sources, events: events,
                unprovenDuplicateBindingIDs: unprovenDuplicateBindingIDs.intersection(bindingIDs),
                snoozes: try loadInboxSnoozes(db)
            )
        }
    }
}

/// One original that an event might be the copy of, and which checks it passed.
public struct InboxCopyDiagnosis: Equatable, Sendable {
    public struct Check: Equatable, Sendable {
        public let name: String
        public let passed: Bool
    }
    public let sourceKeyHash: String
    public let sourceTitle: String?
    public let sourceCalendar: String
    public let armRule: String?
    public let checks: [Check]
    /// A stored copy record for this very event settles it; otherwise every other check must pass.
    public var isCopy: Bool {
        checks.contains { $0.name.hasPrefix("mirror record") && $0.passed } || checks.filter { !$0.name.hasPrefix("mirror record") }.allSatisfy(\.passed)
    }
}

extension LocalStateRepository {
    /// For each event that shares time with an event of another calendar, how the copy checks
    /// came out against that event. Read only; the events are listed before any copy is dropped.
    /// The events the snapshot leaves out as copies, with the originals they copy.
    public func inboxDroppedCopies() throws -> [String: Set<String>] {
        let events = try inboxContextSnapshot(includingCopies: true).events
        return try database.read { copyOriginals(events, try copyContext($0)) }
    }

    public func inboxCopyDiagnoses() throws -> [String: [InboxCopyDiagnosis]] {
        let events = try inboxContextSnapshot(includingCopies: true).events
        return try database.read { db in
            let rows = try copyContext(db)
            var result: [String: [InboxCopyDiagnosis]] = [:]
            for item in events {
                let found = copyDiagnoses(of: item.event, among: events, rows, overlappingOnly: true)
                if !found.isEmpty { result[item.event.sourceKeyHash] = found }
            }
            return result
        }
    }
}

private struct CopyContext {
    let arms: [Row]
    let mapped: [Row]
}

private func copyContext(_ db: Database) throws -> CopyContext {
    CopyContext(
        arms: try Row.fetchAll(db, sql: """
            SELECT a.id, a.target_binding_id, a.rule_mode, a.copy_label, s.calendar_binding_id AS source_binding_id,
                   a.pad_before_minutes, a.pad_after_minutes, a.pad_in_person_only
            FROM arms a JOIN arm_sources s ON s.arm_id = a.id WHERE a.is_enabled = 1
            """),
        mapped: try Row.fetchAll(db, sql: """
            SELECT m.source_key_hash, m.provider_event_id, m.provider_external_id, a.rule_mode, a.copy_label, a.target_binding_id,
                   a.pad_before_minutes, a.pad_after_minutes, a.pad_in_person_only
            FROM mirror_mappings m JOIN arms a ON a.id = m.arm_id
            """))
}

private func guestSet(_ event: StoredNormalizedInstance) -> Set<String> {
    Set(event.attendees.map { ($0.emailAddress ?? $0.name ?? "").lowercased() })
}

/// Everyone the original names: its guests and its organizer.
private func participants(_ event: StoredNormalizedInstance) -> Set<String> {
    guestSet(event).union(event.organizer.map { [($0.emailAddress ?? $0.name ?? "").lowercased()] } ?? [])
}

private func copyPadding(_ row: Row) -> ArmPadding {
    guard ArmRuleMode(rawValue: row["rule_mode"]) != .fullDetails else { return ArmPadding() }
    return ArmPadding(
        beforeMinutes: row["pad_before_minutes"], afterMinutes: row["pad_after_minutes"],
        inPersonOnly: row["pad_in_person_only"])
}

private func copyTitle(mode: String, label: String?, of source: StoredNormalizedInstance) -> String {
    switch ArmRuleMode(rawValue: mode) {
    case .fullDetails: return source.title ?? ""
    case .label:
        let text = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isPrivate || text.isEmpty ? "Busy" : text
    default: return "Busy"
    }
}

private func copyDiagnoses(
    of event: StoredNormalizedInstance, among events: [InboxContextEvent], _ context: CopyContext,
    overlappingOnly: Bool = false
) -> [InboxCopyDiagnosis] {
    var found: [InboxCopyDiagnosis] = []
    for other in events.map(\.event) where other.sourceKeyHash != event.sourceKeyHash
        && other.calendarBindingID != event.calendarBindingID {
        if overlappingOnly && !(other.startsAt < event.endsAt && event.startsAt < other.endsAt) { continue }
        let routes = context.arms.filter { ($0["source_binding_id"] as String) == other.calendarBindingID }
        let stored = context.mapped.filter { ($0["source_key_hash"] as String) == other.sourceKeyHash }
        let modes = routes.map {
            ($0["rule_mode"] as String, $0["copy_label"] as String?, ($0["target_binding_id"] as String) == event.calendarBindingID, copyPadding($0))
        } + stored.map { ($0["rule_mode"] as String, $0["copy_label"] as String?, true, copyPadding($0)) }
        guard !modes.isEmpty else { continue }
        for (mode, label, routedHere, padding) in modes {
            let span = padding.padded(
                startsAt: other.startsAt, endsAt: other.endsAt, isAllDay: other.isAllDay,
                location: other.location, url: other.url, notes: other.notes)
            let sameSpan = span.startsAt == event.startsAt && span.endsAt == event.endsAt
            if !overlappingOnly && !sameSpan { continue }
            let title = copyTitle(mode: mode, label: label, of: other)
            let mine = guestSet(event)
            let checks: [InboxCopyDiagnosis.Check] = [
                .init(name: "arm routes the source calendar to this calendar", passed: routedHere),
                .init(name: "mirror record for the source matches this event id",
                      passed: stored.contains { ($0["provider_event_id"] as String) == event.providerEventID }),
                .init(name: "mirror record for the source matches this event's server id",
                      passed: event.providerExternalID.map { id in stored.contains {
                          ($0["provider_external_id"] as String?) == id
                              && ($0["target_binding_id"] as String) == event.calendarBindingID
                      } } ?? false),
                .init(name: "start and end equal", passed: sameSpan && other.isAllDay == event.isAllDay),
                .init(name: "title equal to the source's (or Busy)", passed: title == (event.title ?? "")),
                .init(name: "guests empty or within the source's people", passed: mine.isEmpty || mine.isSubset(of: participants(other))),
                .init(name: "no invitation reply from the user on it (organizer of the copy is allowed)",
                      passed: ![EventResponseState.needsResponse, .accepted, .tentative, .declined].contains(event.currentUserResponse.state)),
            ]
            found.append(InboxCopyDiagnosis(
                sourceKeyHash: other.sourceKeyHash, sourceTitle: other.title, sourceCalendar: other.calendarBindingID,
                armRule: mode, checks: checks))
        }
    }
    return found
}

/// A copy can come back without its marker or with a new id, so the mapping misses it: the
/// calendar read through a second connection, or an id that changed after a sync. It is still
/// taken for a copy of one of our events when an arm routes that event's calendar into the
/// copy's calendar (or the event has a stored copy), and the copy has the same time, the title
/// the copy would carry, no guests or only the original's people, and no invitation
/// reply from the user. A real invitation always carries a reply, so it is never hidden.
private func droppingUnmarkedCopies(_ events: [InboxContextEvent], _ db: Database) throws -> [InboxContextEvent] {
    let context = try copyContext(db)
    guard !context.arms.isEmpty || !context.mapped.isEmpty else { return events }
    let copies = copyOriginals(events, context)
    return events.filter { copies[$0.event.sourceKeyHash] == nil }
}

/// For each event taken for a copy, the originals it is a copy of. An event that is itself an
/// original is no excuse: a leaked copy is read as a source by the arms that read its calendar,
/// so it has mapped copies of its own. Two events that each look like the other's copy are
/// both kept.
private func copyOriginals(_ events: [InboxContextEvent], _ context: CopyContext) -> [String: Set<String>] {
    var originals: [String: Set<String>] = [:]
    for item in events {
        let found = copyDiagnoses(of: item.event, among: events, context).filter(\.isCopy).map(\.sourceKeyHash)
        if !found.isEmpty { originals[item.event.sourceKeyHash] = Set(found) }
    }
    return originals.filter { key, sources in !sources.allSatisfy { originals[$0]?.contains(key) == true } }
}
