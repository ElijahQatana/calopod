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

    public init(
        id: String, name: String, account: String, provider: String,
        freshness: ScheduleFreshness = .current, coverage: ClosedRange<Date>? = nil
    ) {
        self.id = id
        self.name = name
        self.account = account
        self.provider = provider
        self.freshness = freshness
        self.coverage = coverage
    }
}

public enum ScheduleResponse: String, Equatable, Sendable {
    case accepted, tentative, declined, needsResponse, organizer, none
}

public struct ScheduleCopy: Equatable, Sendable {
    public let calendarName: String
    public let fullDetails: Bool

    public init(calendarName: String, fullDetails: Bool) {
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
    /// A Busy copy Calopod made. It has no reply and no organizer.
    public let isCopy: Bool
    /// Titles of events this one overlaps, for the inspector.
    public let overlaps: [String]
    public let changedSinceViewed: Bool
    public let copiedTo: [ScheduleCopy]
    /// Yes, Maybe, No that the provider allows. Empty when it does not.
    public let replies: [ConflictChoice]
    public let replyUnavailableReason: String?

    public init(
        id: String, calendarID: String, title: String, startsAt: Date, endsAt: Date,
        isAllDay: Bool = false, location: String? = nil, organizer: String? = nil,
        response: ScheduleResponse = .accepted, isCopy: Bool = false, overlaps: [String] = [],
        changedSinceViewed: Bool = false, copiedTo: [ScheduleCopy] = [],
        replies: [ConflictChoice] = [], replyUnavailableReason: String? = nil
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
        self.isCopy = isCopy
        self.overlaps = overlaps
        self.changedSinceViewed = changedSinceViewed
        self.copiedTo = copiedTo
        self.replies = replies
        self.replyUnavailableReason = replyUnavailableReason
    }
}

public struct CalendarSchedule: Equatable, Sendable {
    public let calendars: [ScheduleCalendar]
    public let events: [ScheduleEvent]

    public init(calendars: [ScheduleCalendar], events: [ScheduleEvent]) {
        self.calendars = calendars
        self.events = events
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
                coverage: source.coverage.flatMap { $0.startsAt <= $0.endsAt ? $0.startsAt...$0.endsAt : nil })
        }

        // Overlaps and changes use the same rules as Inbox.
        let analysis = InboxConflictCalculator.analyze(snapshot, window: nil, freshnessCutoff: cutoff)
        let titles = Dictionary(
            snapshot.events.map { ($0.event.sourceKeyHash, Self.title($0.event)) }, uniquingKeysWith: { first, _ in first })
        var overlapping: [String: [String]] = [:]
        for conflict in analysis.conflicts where conflict.isConfirmed {
            overlapping[conflict.pair.first, default: []].append(titles[conflict.pair.second] ?? "Untitled event")
            overlapping[conflict.pair.second, default: []].append(titles[conflict.pair.first] ?? "Untitled event")
        }

        // Where each event is copied. The copies themselves are not stored as events.
        var copies: [String: [(binding: String, fullDetails: Bool)]] = [:]
        for arm in try repository.arms() where arm.isEnabled {
            for mapping in try repository.mirrorMappings(armID: arm.id) {
                copies[mapping.sourceKeyHash, default: []]
                    .append((arm.targetBindingID, arm.ruleMode == .fullDetails))
            }
        }
        func calendarName(_ binding: String) -> String {
            if let known = names[binding] { return known }
            let stored = try? repository.calendarBinding(id: binding)
            return stored?.displayLabel ?? "Another calendar"
        }

        var events: [ScheduleEvent] = []
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
            events.append(ScheduleEvent(
                id: event.sourceKeyHash, calendarID: event.calendarBindingID, title: Self.title(event),
                startsAt: event.startsAt, endsAt: event.endsAt, isAllDay: event.isAllDay,
                location: event.location.flatMap { $0.isEmpty ? nil : $0 },
                organizer: event.organizer.flatMap { $0.name ?? $0.emailAddress },
                response: Self.response(event.currentUserResponse.state),
                overlaps: overlapping[event.sourceKeyHash] ?? [],
                changedSinceViewed: item.observation.map { $0.revision > max($0.acknowledgedRevision ?? 0, 1) } ?? false,
                copiedTo: targets.map { ScheduleCopy(calendarName: calendarName($0.binding), fullDetails: $0.fullDetails) },
                replies: replies,
                replyUnavailableReason: replies.isEmpty ? ConflictResolutionService.reasonText(choices.unavailableReasons) : nil
            ))
            // The copy is drawn at the source's time on the calendar that holds it.
            for target in targets where names[target.binding] != nil && target.binding != event.calendarBindingID {
                events.append(ScheduleEvent(
                    id: "copy:\(target.binding):\(event.sourceKeyHash)", calendarID: target.binding,
                    title: target.fullDetails ? Self.title(event) : "Busy",
                    startsAt: event.startsAt, endsAt: event.endsAt, isAllDay: event.isAllDay,
                    response: .none, isCopy: true,
                    replyUnavailableReason: ConflictResolutionService.reasonText([.managedMirror])))
            }
        }
        return CalendarSchedule(calendars: calendars, events: events)
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

    private static func response(_ state: EventResponseState) -> ScheduleResponse {
        switch state {
        case .accepted: .accepted
        case .tentative: .tentative
        case .declined: .declined
        case .needsResponse: .needsResponse
        case .organizer: .organizer
        case .notApplicable, .unknown: .none
        }
    }
}
#endif
