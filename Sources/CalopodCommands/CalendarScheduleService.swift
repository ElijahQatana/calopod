#if os(macOS)
import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation

/// How current a calendar's local copy is.
public enum ScheduleFreshness: Equatable, Sendable {
    case current
    /// The last read failed or is old. `since` is when it went stale, if known.
    case stale(since: Date?)
    /// Never read, so nothing is known about it yet.
    case unread
}

public struct ScheduleCalendar: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let account: String
    public let provider: String
    public let freshness: ScheduleFreshness
    /// The range last read completely, when known.
    public let coverage: ClosedRange<Date>?
    /// When the local copy was last read, when known.
    public let readAt: Date?
    public let providerColor: String?

    public init(
        id: String, name: String, account: String, provider: String,
        freshness: ScheduleFreshness = .current, coverage: ClosedRange<Date>? = nil,
        readAt: Date? = nil, providerColor: String? = nil
    ) {
        self.id = id
        self.name = name
        self.account = account
        self.provider = provider
        self.freshness = freshness
        self.coverage = coverage
        self.readAt = readAt
        self.providerColor = providerColor
    }
}

/// Whether Inbox lists this event as changed after the user answered.
public enum ScheduleChange: Equatable, Sendable {
    case none
    case changed
    /// The edit may have come before the reply, so it is not shown as a proven change.
    case uncertain
}

public enum ScheduleResponse: String, Equatable, Sendable {
    case accepted, tentative, declined, needsResponse, organizer, none

    public init(_ state: EventResponseState) {
        switch state {
        case .accepted: self = .accepted
        case .tentative: self = .tentative
        case .declined: self = .declined
        case .needsResponse: self = .needsResponse
        case .organizer: self = .organizer
        case .notApplicable, .unknown: self = .none
        }
    }
}

public enum ScheduleCopyMode: String, Equatable, Sendable {
    case fullDetails, busy
}

/// Where a copy Calopod made came from. Worked out once per schedule load.
public struct ScheduleCopyOrigin: Equatable, Sendable {
    public let mode: ScheduleCopyMode
    public let armName: String
    public let sourceEventID: String
    public let sourceCalendarID: String
    public let sourceCalendarName: String
    /// The current user's answer on the original; `.none` when it is not known.
    public let sourceResponse: ScheduleResponse

    public init(
        mode: ScheduleCopyMode, armName: String, sourceEventID: String, sourceCalendarID: String,
        sourceCalendarName: String, sourceResponse: ScheduleResponse
    ) {
        self.mode = mode
        self.armName = armName
        self.sourceEventID = sourceEventID
        self.sourceCalendarID = sourceCalendarID
        self.sourceCalendarName = sourceCalendarName
        self.sourceResponse = sourceResponse
    }
}

public struct ScheduleCopy: Equatable, Sendable {
    public let calendarName: String
    public let fullDetails: Bool
    public let calendarID: String

    public init(calendarName: String, fullDetails: Bool, calendarID: String = "") {
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.fullDetails = fullDetails
    }
}

public struct ScheduleEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    public let location: String?
    public let organizer: String?
    public let response: ScheduleResponse
    /// A copy Calopod made, full details or Busy. It has no reply and no organizer.
    public let isCopy: Bool
    /// What kind of copy this is and where it came from. Nil for events, and for a copy whose origin is not known.
    public let copyOrigin: ScheduleCopyOrigin?
    /// Titles of events this one overlaps, for the inspector.
    public let overlaps: [String]
    /// Titles of Calopod copies drawn over this event that are not already in `overlaps`.
    public let copyOverlaps: [String]
    public let change: ScheduleChange
    public let copiedTo: [ScheduleCopy]
    /// Yes, Maybe, No that the provider allows. Empty when it does not.
    public let replies: [ConflictChoice]
    public let replyUnavailableReason: String?
    /// The Teams, Zoom, Meet or Webex link in the event. Copies never have one.
    public let meeting: MeetingLink?
    public let isRecurring: Bool
    public let isSkipped: Bool

    public init(
        id: String, calendarID: String, title: String, startsAt: Date, endsAt: Date,
        isAllDay: Bool = false, location: String? = nil, organizer: String? = nil,
        response: ScheduleResponse = .accepted, isCopy: Bool = false, copyOrigin: ScheduleCopyOrigin? = nil, overlaps: [String] = [], copyOverlaps: [String] = [],
        change: ScheduleChange = .none, copiedTo: [ScheduleCopy] = [],
        replies: [ConflictChoice] = [], replyUnavailableReason: String? = nil, meeting: MeetingLink? = nil,
        isRecurring: Bool = false, isSkipped: Bool = false
    ) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.location = location
        self.organizer = organizer
        self.response = response
        self.isCopy = isCopy || copyOrigin != nil
        self.copyOrigin = copyOrigin
        self.overlaps = overlaps
        self.copyOverlaps = copyOverlaps
        self.change = change
        self.copiedTo = copiedTo
        self.replies = replies
        self.replyUnavailableReason = replyUnavailableReason
        self.meeting = meeting
        self.isRecurring = isRecurring
        self.isSkipped = isSkipped
    }
}

extension ScheduleEvent {
    /// The answer that decides how the block looks: a copy carries its original's answer.
    public var carriedResponse: ScheduleResponse { copyOrigin?.sourceResponse ?? response }

    fileprivate func withCopyOverlaps(_ titles: [String]) -> ScheduleEvent {
        ScheduleEvent(
            id: id, calendarID: calendarID, title: title, startsAt: startsAt, endsAt: endsAt,
            isAllDay: isAllDay, location: location, organizer: organizer, response: response,
            isCopy: isCopy, copyOrigin: copyOrigin, overlaps: overlaps, copyOverlaps: titles, change: change,
            copiedTo: copiedTo, replies: replies, replyUnavailableReason: replyUnavailableReason, meeting: meeting,
            isRecurring: isRecurring, isSkipped: isSkipped)
    }
}

public struct CalendarSchedule: Equatable, Sendable {
    public let calendars: [ScheduleCalendar]
    public let events: [ScheduleEvent]
    /// What each calendar does for the active arms, for the Sources and Destinations views.
    public let roles: CalendarRoles

    public init(calendars: [ScheduleCalendar], events: [ScheduleEvent], roles: CalendarRoles = CalendarRoles()) {
        self.calendars = calendars
        self.events = events
        self.roles = roles
    }
}

/// Reads the local copy for the Calendar screen. It never contacts a provider.
public struct CalendarScheduleService: Sendable {
    private let makeRepository: @Sendable () throws -> LocalStateRepository
    private let now: @Sendable () -> Date

    public init() {
        makeRepository = { try CommandEnvironment.repository() }
        now = Date.init
    }

    init(makeRepository: @escaping @Sendable () throws -> LocalStateRepository, now: @escaping @Sendable () -> Date = Date.init) {
        self.makeRepository = makeRepository
        self.now = now
    }

    public func schedule() throws -> CalendarSchedule {
        let repository = try makeRepository()
        let snapshot = try repository.inboxContextSnapshot()
        let cutoff = now().addingTimeInterval(-3600)
        let names = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.bindingID, Self.name(of: $0)) })

        let calendars = snapshot.sources.map { source in
            ScheduleCalendar(
                id: source.bindingID, name: names[source.bindingID] ?? "Calendar",
                account: source.connectionLabel ?? source.provider, provider: source.provider,
                freshness: Self.freshness(of: source, cutoff: cutoff),
                coverage: source.coverage.flatMap { $0.startsAt <= $0.endsAt ? $0.startsAt...$0.endsAt : nil },
                readAt: source.coverage?.observedAt, providerColor: source.providerColor)
        }

        // Overlaps and changes use the same rules as Inbox.
        let analysis = InboxConflictCalculator.analyze(snapshot, window: nil, freshnessCutoff: cutoff)
        let titles = Dictionary(
            snapshot.events.map { ($0.event.sourceKeyHash, Self.title($0.event)) }, uniquingKeysWith: { first, _ in first })
        // The changed dot is exactly the set Inbox lists as changed, with no rule of its own.
        var changes: [String: ScheduleChange] = [:]
        for row in InboxAttentionQuery.evaluate(snapshot, filter: InboxAttentionFilter(asOf: now()), freshnessCutoff: cutoff).rows
        where row.reasons.contains(.changedAfterResponse) {
            changes[row.item.event.sourceKeyHash] = row.changeTiming == .uncertain ? .uncertain : .changed
        }
        var overlapping: [String: [String]] = [:]
        var overlapIDs: [String: Set<String>] = [:]
        for conflict in analysis.conflicts where conflict.isConfirmed {
            overlapIDs[conflict.pair.first, default: []].insert(conflict.pair.second)
            overlapIDs[conflict.pair.second, default: []].insert(conflict.pair.first)
            overlapping[conflict.pair.first, default: []].append(titles[conflict.pair.second] ?? "Untitled event")
            overlapping[conflict.pair.second, default: []].append(titles[conflict.pair.first] ?? "Untitled event")
        }

        // Where each event is copied. The copies themselves are not stored as events.
        let allArms = try repository.arms()
        let skips = try repository.eventSkips()
        let copies = try CopyTarget.bySource(repository, arms: allArms)
        func calendarName(_ binding: String) -> String {
            if let known = names[binding] { return known }
            let stored = try? repository.calendarBinding(id: binding)
            return stored?.displayLabel ?? "Another calendar"
        }

        var events: [ScheduleEvent] = []
        var copySources: [String: String] = [:]
        for item in snapshot.events where item.isPresenceConfirmed {
            let event = item.event
            let choices = InboxCalendarContextBuilder.choices(for: item, snapshot: snapshot)
            let replies = choices.choices.compactMap { choice -> ConflictChoice? in
                switch choice {
                case .yes: .yes
                case .maybe: .maybe
                case .no: .no
                case .hold: nil
                }
            }
            let targets = copies[event.sourceKeyHash] ?? []
            let sourceResponse = Self.response(event.currentUserResponse.state)
            events.append(ScheduleEvent(
                id: event.sourceKeyHash, calendarID: event.calendarBindingID, title: Self.title(event),
                startsAt: event.startsAt, endsAt: event.endsAt, isAllDay: event.isAllDay,
                location: event.location.flatMap { $0.isEmpty ? nil : $0 },
                organizer: event.organizer.flatMap { $0.name ?? $0.emailAddress },
                response: sourceResponse,
                overlaps: overlapping[event.sourceKeyHash] ?? [],
                change: changes[event.sourceKeyHash] ?? .none,
                copiedTo: targets.map { ScheduleCopy(calendarName: calendarName($0.bindingID), fullDetails: $0.fullDetails, calendarID: $0.bindingID) },
                replies: replies,
                replyUnavailableReason: replies.isEmpty ? ConflictResolutionService.reasonText(choices.unavailableReasons) : nil,
                meeting: JoinSelector.link(for: event),
                isRecurring: event.providerSeriesID != nil,
                isSkipped: skips.contains { $0.matches(event) }
            ))
            // The copy is drawn at the source's time on the calendar that holds it.
            for target in targets where names[target.bindingID] != nil && target.bindingID != event.calendarBindingID {
                copySources["copy:\(target.bindingID):\(event.sourceKeyHash)"] = event.sourceKeyHash
                let origin = ScheduleCopyOrigin(
                    mode: target.fullDetails ? .fullDetails : .busy, armName: target.armName,
                    sourceEventID: event.sourceKeyHash, sourceCalendarID: event.calendarBindingID,
                    sourceCalendarName: calendarName(event.calendarBindingID), sourceResponse: sourceResponse)
                events.append(ScheduleEvent(
                    id: "copy:\(target.bindingID):\(event.sourceKeyHash)", calendarID: target.bindingID,
                    title: target.fullDetails ? Self.title(event) : target.arm.plainCopyTitle(isPrivate: event.isPrivate),
                    startsAt: event.startsAt, endsAt: event.endsAt, isAllDay: event.isAllDay,
                    response: .none, copyOrigin: origin,
                    replyUnavailableReason: ConflictResolutionService.reasonText([.managedMirror])))
            }
        }
        // Copies are drawn on the grid but are not events in the overlap check. Name the ones
        // that sit over an event so the inspector does not claim nothing overlaps.
        let drawnCopies = events.filter(\.isCopy)
        events = events.map { event in
            guard !event.isCopy, event.overlaps.isEmpty, !event.isAllDay else { return event }
            let hits = drawnCopies.filter { copy in
                !copy.isAllDay && copy.startsAt < event.endsAt && event.startsAt < copy.endsAt
                    && copySources[copy.id] != event.id
                    && !(overlapIDs[event.id]?.contains(copySources[copy.id] ?? "") ?? false)
            }
            return hits.isEmpty ? event : event.withCopyOverlaps(hits.map(\.title))
        }
        return CalendarSchedule(calendars: calendars, events: events, roles: CalendarRoles(arms: allArms))
    }

    private static func title(_ event: StoredNormalizedInstance) -> String {
        event.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled event"
    }

    private static func name(of source: InboxContextSource) -> String {
        source.calendarLabel ?? source.connectionLabel ?? "Calendar"
    }

    private static func freshness(of source: InboxContextSource, cutoff: Date) -> ScheduleFreshness {
        if source.coverage == nil && source.healthStatus == nil { return .unread }
        if source.staleSince != nil || (source.healthStatus.map { $0 != "healthy" } ?? false) {
            return .stale(since: source.staleSince)
        }
        if let observed = source.coverage?.observedAt, observed < cutoff { return .stale(since: observed) }
        return .current
    }

    private static func response(_ state: EventResponseState) -> ScheduleResponse { ScheduleResponse(state) }
}
#endif
