#if os(macOS)
import CalopodDomain
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation

/// The Mac Inbox filters. Each one selects rows by the shared attention reasons.
public enum InboxFilter: String, CaseIterable, Identifiable, Sendable {
    case all, needsRSVP, maybe, changed, conflicts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .needsRSVP: "Needs RSVP"
        case .maybe: "Maybe"
        case .changed: "Changed"
        case .conflicts: "Conflicts"
        }
    }

    func matches(_ reasons: [InboxAttentionReason]) -> Bool {
        switch self {
        case .all: true
        case .needsRSVP: reasons.contains(.needsResponse)
        case .maybe: reasons.contains(.maybe)
        case .changed: reasons.contains(.changedAfterResponse)
        case .conflicts: reasons.contains(.conflict)
        }
    }
}

public struct InboxEntry: Identifiable, Equatable, Sendable {
    public let id: String
    /// `event:revision`, as `calopod inbox --ids` prints it.
    public let revisionID: String
    public let title: String
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    public let calendarID: String
    public let calendarName: String
    public let organizer: String?
    public let location: String?
    public let response: EventResponseState
    public let reasons: [InboxAttentionReason]
    /// The edit may have come before the reply, so it is not shown as a proven change.
    public let changeIsUncertain: Bool
    public let overlapCount: Int
    public var meeting: MeetingLink?

    /// Only a change after a reply can be acknowledged.
    public var canAcknowledge: Bool { reasons.contains(.changedAfterResponse) }
}

public struct InboxBoard: Equatable, Sendable {
    public let entries: [InboxEntry]
    /// Calendars that are stale or only partly read.
    public let incompleteCalendars: [String]
    public let isComplete: Bool
    /// When the calendars were last read.
    public let lastChecked: Date?

    /// Names the calendars that are behind, or says some are when none can be named.
    public func staleText(suffix: String) -> String {
        let which = incompleteCalendars.isEmpty
            ? "Some calendars are"
            : incompleteCalendars.joined(separator: ", ") + (incompleteCalendars.count == 1 ? " is" : " are")
        return "\(which) out of date or only partly read, \(suffix)"
    }

    public func entries(for filter: InboxFilter) -> [InboxEntry] { entries.filter { filter.matches($0.reasons) } }
    public func count(_ filter: InboxFilter) -> Int { entries(for: filter).count }
}

public struct InboxContextEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let calendarID: String
    public let calendarName: String
    public let startsAt: Date
    public let endsAt: Date
    public let isFocused: Bool
    public let overlapsFocused: Bool
    public let response: EventResponseState

    public init(id: String, title: String, calendarID: String, calendarName: String, startsAt: Date, endsAt: Date,
                isFocused: Bool, overlapsFocused: Bool, response: EventResponseState = .unknown) {
        self.id = id
        self.title = title
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isFocused = isFocused
        self.overlapsFocused = overlapsFocused
        self.response = response
    }
}

public struct InboxDetail: Equatable, Sendable {
    public let entry: InboxEntry
    /// Window shown in the context strip.
    public let windowStart: Date
    public let windowEnd: Date
    public let context: [InboxContextEntry]
    /// Replies the calendar allows. Empty when only Hold is possible.
    public let replies: [ConflictChoice]
    public let replyNote: String
    /// Connection and calendar the reply goes through, for the confirm step.
    public var account = ""
    public var connection = ""
    /// What would still overlap after each answer.
    public var previews: [InboxReviewPreview] = []
    /// The Calendar app's id for the event, set for calendars read through the Mac and answered there.
    public var calendarEventID: String?

    /// True when replies are made in the Calendar app, so Inbox offers to open the event there.
    public var canOpenInCalendar: Bool { calendarEventID != nil && replies.isEmpty }

    public func preview(for reply: ConflictChoice) -> InboxReviewPreview? { previews.first { $0.reply == reply } }
}

public struct InboxReplyResult: Equatable, Sendable {
    public let status: ConflictApplyReport.Status
    public let message: String

    public init(status: ConflictApplyReport.Status, message: String) {
        self.status = status
        self.message = message
    }
}

/// Backs the Mac Inbox screen from the same local copy and rules as `calopod inbox`.
public struct InboxScreenService: Sendable {
    private let makeRepository: @Sendable () throws -> LocalStateRepository
    private let makeLockURL: @Sendable () throws -> URL
    private let makeRefresh: @Sendable (LocalStateRepository) -> InboxReviewSessionController.Refresh
    private let provider: InboxReviewSessionController.Provider
    private let now: @Sendable () -> Date

    public init() {
        makeRepository = { try CommandEnvironment.repository() }
        makeLockURL = { try CommandEnvironment.runtimeEnvironment().stateLocation.lockURL }
        makeRefresh = { inboxReviewRefresh(state: $0) }
        provider = inboxReviewProvider()
        now = Date.init
    }

    init(
        makeRepository: @escaping @Sendable () throws -> LocalStateRepository,
        makeLockURL: @escaping @Sendable () throws -> URL,
        makeRefresh: @escaping @Sendable (LocalStateRepository) -> InboxReviewSessionController.Refresh,
        provider: @escaping InboxReviewSessionController.Provider,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.makeRepository = makeRepository
        self.makeLockURL = makeLockURL
        self.makeRefresh = makeRefresh
        self.provider = provider
        self.now = now
    }

    private var freshnessCutoff: Date { now().addingTimeInterval(-3600) }

    // MARK: Reading

    /// Everything that needs attention, from the local copy. Never contacts a calendar.
    public func board() throws -> InboxBoard {
        let snapshot = try makeRepository().inboxContextSnapshot()
        let result = InboxAttentionQuery.evaluate(
            snapshot, filter: InboxAttentionFilter(asOf: now()), freshnessCutoff: freshnessCutoff)
        let entries = result.rows.map { entry($0, in: snapshot) }
        let incomplete = Set(result.analysis.warnings.compactMap { warning -> String? in
            guard [.staleSource, .incompleteCoverage, .unknownSource].contains(warning.kind),
                  let id = warning.bindingID else { return nil }
            return label(of: id, in: snapshot)
        })
        return InboxBoard(
            entries: entries, incompleteCalendars: incomplete.sorted(), isComplete: result.analysis.isComplete,
            lastChecked: snapshot.sources.compactMap { $0.coverage?.observedAt }.max()
        )
    }

    /// One event with its surroundings and the replies available for it.
    public func detail(for id: String, settings: InboxContextSettings? = nil) throws -> InboxDetail {
        let state = try makeRepository()
        let snapshot = try state.inboxContextSnapshot()
        let result = InboxAttentionQuery.evaluate(
            snapshot, filter: InboxAttentionFilter(asOf: now()), freshnessCutoff: freshnessCutoff)
        guard let row = result.rows.first(where: { $0.item.event.sourceKeyHash == id }) else {
            throw InboxCalendarContextError.eventUnavailable
        }
        let context = try InboxCalendarContextBuilder.build(
            snapshot: snapshot, focusedKey: id, settings: try settings ?? state.inboxContextSettings(),
            freshnessCutoff: freshnessCutoff)
        let focused = context.focused.event
        let choices = context.choices.first { $0.sourceKeyHash == id }
            ?? InboxCalendarContextBuilder.choices(for: context.focused, snapshot: snapshot)
        let replies = choices.choices.compactMap(Self.reply)
        let remaining = context.projections.first { $0.choice == .yes }?.conflicts.filter(\.isConfirmed).count ?? 0
        return InboxDetail(
            entry: entry(row, in: snapshot),
            windowStart: context.visibleWindow.start, windowEnd: context.visibleWindow.end,
            context: Self.contextEntries(context, focusedKey: id),
            replies: replies,
            replyNote: replies.isEmpty
                ? ConflictResolutionService.reasonText(choices.unavailableReasons)
                : Self.note(organizer: focused.organizer, overlapsAfterYes: remaining),
            account: Self.accountLabel(context.source), connection: context.source.connectionLabel ?? context.source.provider,
            previews: Self.previews(for: replies, in: context, key: id),
            calendarEventID: context.source.provider == "eventkit" ? focused.providerEventID : nil
        )
    }

    // MARK: Acting

    /// Rereads the selected calendars under the sync lock. Throws `busy` if something else holds it.
    public func refresh() async throws {
        let state = try makeRepository()
        let lock = try ProcessLock.acquire(at: try makeLockURL())
        defer { withExtendedLifetime(lock) {} }
        _ = try await makeRefresh(state)()
    }

    /// Marks one displayed change as seen on this Mac. Never sends a reply.
    public func acknowledge(revisionID: String) throws {
        let lock = try ProcessLock.acquire(at: try makeLockURL())
        defer { withExtendedLifetime(lock) {} }
        _ = try InboxCLI.acknowledge(revisionID, repository: try makeRepository())
    }

    /// Sends one explicit reply, revalidated just before it goes. A changed event is skipped and reported.
    public func reply(to id: String, _ choice: ConflictChoice) async -> InboxReplyResult {
        func result(_ line: ConflictApplyReport.Line) -> InboxReplyResult { .init(status: line.status, message: line.message) }
        let make: (ConflictApplyReport.Status, String) -> ConflictApplyReport.Line = {
            .init(eventID: id, title: "", choice: choice, status: $0, message: $1)
        }
        guard choice != .noChange else { return .init(status: .unavailable, message: "Pick Yes, Maybe or No.") }
        var cleanup: (() -> Void)?
        defer { cleanup?() }
        do {
            let state = try makeRepository()
            let cutoff = freshnessCutoff
            let snapshot = try state.inboxContextSnapshot()
            let queue = InboxAttentionQuery.evaluate(snapshot, freshnessCutoff: cutoff)
            let controller = InboxReviewSessionController(state: state, lockURL: try makeLockURL(), now: now)
            let refresh = makeRefresh(state)
            let session = try controller.start(
                metricsWindow: queue.analysisWindow ?? SyncWindow(start: now(), end: now().addingTimeInterval(1)),
                freshnessCutoff: cutoff)
            // A single reply must not leave a review behind for Resume to pick up. A session with an
            // unclear outcome is kept.
            cleanup = { try? state.discardInboxReviewSession(id: session.id) }
            guard let card = try await controller.card(
                sessionID: session.id, sourceKeyHash: id, freshnessCutoff: cutoff, refresh: refresh, provider: provider
            ) else {
                return result(make(.failed, "Calopod could not open this event. Nothing was sent."))
            }
            let done = try await controller.decide(
                choice.inbox, card: card, freshnessCutoff: cutoff, refresh: refresh, provider: provider)
            return result(ConflictResolutionService.line(
                for: done.entries.first { $0.sourceKeyHash == id }?.outcome, make: make))
        } catch {
            return result(ConflictResolutionService.failureLine(error, make: make))
        }
    }

    // MARK: Helpers

    private func entry(_ row: InboxAttentionRow, in snapshot: InboxContextSnapshot) -> InboxEntry {
        Self.entry(row.item.event, observation: row.item.observation, source: row.source, reasons: row.reasons,
                   changeIsUncertain: row.changeTiming == .uncertain, overlapCount: row.conflicts.count)
    }

    static func entry(_ event: StoredNormalizedInstance, observation: InboxObservation?, source: InboxContextSource,
                      reasons: [InboxAttentionReason], changeIsUncertain: Bool, overlapCount: Int) -> InboxEntry {
        let organizer = event.organizer.flatMap { $0.name ?? $0.emailAddress }
        return InboxEntry(
            id: event.sourceKeyHash,
            revisionID: InboxCLI.id(event.sourceKeyHash, observation?.revision ?? 1),
            title: event.title?.isEmpty == false ? event.title! : "Untitled event",
            startsAt: event.startsAt, endsAt: event.endsAt, isAllDay: event.isAllDay,
            calendarID: event.calendarBindingID,
            calendarName: source.calendarLabel ?? source.connectionLabel ?? "Unknown calendar",
            organizer: organizer, location: event.location,
            response: event.currentUserResponse.state, reasons: reasons,
            changeIsUncertain: changeIsUncertain, overlapCount: overlapCount, meeting: JoinSelector.link(for: event))
    }

    /// The strip of surrounding events. `focusedKey` is the one being looked at.
    static func contextEntries(_ context: InboxCalendarContext, focusedKey: String) -> [InboxContextEntry] {
        let overlapping = Set(context.focusedConflicts.flatMap { [$0.pair.first, $0.pair.second] })
        return context.rows.map {
            InboxContextEntry(
                id: $0.event.event.sourceKeyHash, title: $0.event.event.title ?? "Untitled event",
                calendarID: $0.event.event.calendarBindingID,
                calendarName: $0.source.calendarLabel ?? $0.source.connectionLabel ?? "Calendar",
                startsAt: $0.visibleInterval.start, endsAt: $0.visibleInterval.end, isFocused: $0.isFocused,
                overlapsFocused: $0.event.event.sourceKeyHash != focusedKey && overlapping.contains($0.event.event.sourceKeyHash),
                response: $0.event.event.currentUserResponse.state)
        }
    }

    private func label(of bindingID: String, in snapshot: InboxContextSnapshot) -> String {
        let source = snapshot.sources.first { $0.bindingID == bindingID }
        return source?.calendarLabel ?? source?.connectionLabel ?? "A calendar"
    }

    static func accountLabel(_ source: InboxContextSource) -> String {
        [source.connectionLabel ?? source.provider, source.calendarLabel].compactMap { $0 }.joined(separator: " / ")
    }

    /// Titles of the events that would still overlap after each answer.
    static func previews(for replies: [ConflictChoice], in context: InboxCalendarContext, key: String) -> [InboxReviewPreview] {
        replies.map { reply in
            let projection = context.projections.first { $0.choice == reply.inbox }
            let titles = (projection?.conflicts ?? []).map { conflict -> String in
                let other = conflict.pair.first == key ? conflict.pair.second : conflict.pair.first
                return context.snapshot.events.first { $0.event.sourceKeyHash == other }?.event.title ?? "Untitled event"
            }
            return InboxReviewPreview(reply: reply, overlaps: titles)
        }
    }

    private static func reply(_ choice: InboxConflictChoice) -> ConflictChoice? {
        switch choice {
        case .yes: .yes
        case .no: .no
        case .maybe: .maybe
        case .hold: nil
        }
    }

    private static func note(organizer: EventParticipant?, overlapsAfterYes: Int) -> String {
        let who = organizer.flatMap { $0.name ?? $0.emailAddress } ?? "the organizer"
        let overlaps = switch overlapsAfterYes {
        case 0: "Accepting leaves no overlaps."
        case 1: "Accepting leaves 1 overlap."
        default: "Accepting leaves \(overlapsAfterYes) overlaps."
        }
        return "Yes, Maybe and No send your reply and may notify \(who). \(overlaps)"
    }
}
#endif
