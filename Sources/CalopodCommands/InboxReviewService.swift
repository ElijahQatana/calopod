#if os(macOS)
import CalopodDomain
import CalopodProviders
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation

/// The totals the review summary shows. Reviewed and resolved are different things.
public struct InboxReviewTotals: Equatable, Sendable {
    public let yes, no, maybe, held, unclear, failed, unavailable, changed: Int
    public let overlapsResolved, overlapsCreated, overlapsRemaining: Int
    public let remainingQueue, remainingInbox: Int
    public let queueReviewed, inboxResolved: Bool
    /// False when a calendar was stale or partly read, so overlap counts are lower bounds.
    public let overlapsAreComplete: Bool

    public var recorded: Int { yes + no + maybe }
}

public struct InboxReviewProgress: Equatable, Sendable {
    public let sessionID: String
    public let total: Int
    /// Items with a final outcome for this session, not counting ones that must be read again.
    public let reviewed: Int
    public let isFinished: Bool
    /// A reply whose outcome is not known yet. Resume checks it before anything else.
    public let hasUnclear: Bool
    /// The queued event the sheet is on, when it is not finished.
    public let currentKey: String?
    public let totals: InboxReviewTotals
}

/// What the confirm step shows for one possible answer.
public struct InboxReviewPreview: Equatable, Sendable {
    public let reply: ConflictChoice
    /// Titles of events that would still overlap after this answer.
    public let overlaps: [String]
}

public struct InboxReviewCardInfo: Sendable {
    public let detail: InboxDetail
    /// 1-based place in the queue.
    public let position: Int
    public let total: Int
    public let account: String
    /// The account part of `account`, so a local calendar name can stand in for the rest.
    public let connection: String
    /// True for calendars read through the Mac's Calendar app, where replies are made in that app.
    public let isMacCalendar: Bool
    public let organizer: String?
    /// What sending does, as the provider describes it. Nil when no reply is possible.
    public let notification: String?
    public let previews: [InboxReviewPreview]
    /// Other events in the same overlap group, in the order G1, G2, ... jumps to them.
    public let neighbors: [InboxContextEntry]
    let card: InboxReviewCard

    public var entry: InboxEntry { detail.entry }
    public var replies: [ConflictChoice] { detail.replies }
    public func preview(for reply: ConflictChoice) -> InboxReviewPreview? { previews.first { $0.reply == reply } }
}

public enum InboxReviewStep: Equatable, Sendable {
    case recorded(ConflictChoice)
    case held
    /// The event changed first. Nothing was sent; show it again.
    case changed
    /// The calendar did not take the reply, or it was not allowed. Nothing changed.
    case failed(String)
    /// The outcome is not known. It is never sent again; Resume checks it.
    case unclear
    /// Another job holds the lock. Nothing was sent.
    case busy
}

/// The Mac side of `calopod inbox review`. It drives the same session controller,
/// so the rules for holds, changed events and unclear outcomes are the same.
public struct InboxReviewService: Sendable {
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

    private var cutoff: Date { now().addingTimeInterval(-3600) }

    private func controller() throws -> (InboxReviewSessionController, LocalStateRepository) {
        let state = try makeRepository()
        return (InboxReviewSessionController(state: state, lockURL: try makeLockURL()), state)
    }

    // MARK: Sessions

    /// The saved review that can be continued, if any.
    public func unfinished() throws -> InboxReviewProgress? {
        let (controller, state) = try controller()
        guard let stored = try state.inboxReviewSession() else { return nil }
        return progress(try controller.session(id: stored.id))
    }

    public func start(overlapsOnly: Bool, skipMaybe: Bool) throws -> InboxReviewProgress {
        let (controller, state) = try controller()
        let cutoff = cutoff
        let snapshot = try state.inboxContextSnapshot()
        let window = try InboxAttentionQuery.evaluate(snapshot, freshnessCutoff: cutoff).analysisWindow
            ?? SyncWindow(start: now(), end: now().addingTimeInterval(1))
        let filter = InboxAttentionFilter(
            excludeMaybe: skipMaybe, conflictsOnly: overlapsOnly, bindingIDs: Set(snapshot.sources.map(\.bindingID)),
            asOf: now())
        return progress(try controller.start(
            filter: filter, metricsWindow: window, freshnessCutoff: cutoff,
            displayTimeZoneIdentifier: TimeZone.current.identifier))
    }

    /// Checks any reply with an unknown outcome against the calendar. Never sends one.
    public func resume() async throws -> InboxReviewProgress {
        let (controller, state) = try controller()
        return progress(try await controller.resume(
            freshnessCutoff: cutoff, refresh: makeRefresh(state), provider: provider))
    }

    public func progress(sessionID: String) throws -> InboxReviewProgress {
        progress(try controller().0.session(id: sessionID))
    }

    // MARK: Cards

    /// The next queued event, or the one in `focus` when jumping within an overlap group.
    /// Returns nil when the queue is done.
    public func card(sessionID: String, focus: String? = nil, from origin: String? = nil) async throws -> InboxReviewCardInfo? {
        let (controller, state) = try controller()
        guard let card = try await controller.card(
            sessionID: sessionID, sourceKeyHash: focus, conflictFromKey: origin,
            freshnessCutoff: cutoff, refresh: makeRefresh(state), provider: provider) else { return nil }
        return try info(card, session: controller.session(id: sessionID))
    }

    /// Sends one explicit reply. The event is checked again first; if it changed, nothing is sent.
    public func reply(_ choice: ConflictChoice, card: InboxReviewCardInfo) async -> (InboxReviewStep, InboxReviewProgress?) {
        await decide(choice.inbox, card: card)
    }

    /// Skips the event for this session. Sends and marks nothing.
    public func hold(card: InboxReviewCardInfo) async -> (InboxReviewStep, InboxReviewProgress?) {
        await decide(.hold, card: card)
    }

    /// Holds an event whose card could not be opened. No reply is involved.
    public func holdUnavailable(sessionID: String, key: String) throws -> InboxReviewProgress {
        let (controller, _) = try controller()
        return progress(try controller.deferUnavailable(
            sessionID: sessionID, sourceKeyHash: key, freshnessCutoff: cutoff, hold: true))
    }

    private func decide(_ choice: InboxConflictChoice, card: InboxReviewCardInfo) async -> (InboxReviewStep, InboxReviewProgress?) {
        let sessionID = card.card.sessionID
        let key = card.entry.id
        do {
            let (controller, state) = try controller()
            let done = try await controller.decide(
                choice, card: card.card, freshnessCutoff: cutoff, refresh: makeRefresh(state), provider: provider)
            let outcome = done.entries.first { $0.sourceKeyHash == key }?.outcome
            let step: InboxReviewStep = switch outcome {
            case .confirmed: .recorded(Self.reply(choice))
            case .hold: .held
            case .stale: .changed
            case .failed, .unavailable: .failed(ConflictResolutionService.line(for: outcome, make: Self.line).message)
            default: .unclear
            }
            return (step, progress(done))
        } catch CalopodRuntimeError.busy {
            return (.busy, nil)
        } catch {
            // The intent may already be saved. If so the outcome is unclear, not failed.
            let saved = (try? controller().0.session(id: sessionID)).map(progress)
            if saved?.hasUnclear == true { return (.unclear, saved) }
            // Only an event that moved on is "changed"; any other error is reported as it is.
            let moved = error is InboxReviewSessionError || error is InboxCalendarContextError
                || error as? InboxReviewSessionStoreError == .changed
            return (moved ? .changed : .failed("Calopod could not finish that. Nothing was sent."), saved)
        }
    }

    // MARK: Helpers

    private static func line(_ status: ConflictApplyReport.Status, _ message: String) -> ConflictApplyReport.Line {
        .init(eventID: "", title: "", choice: .noChange, status: status, message: message)
    }

    private static func reply(_ choice: InboxConflictChoice) -> ConflictChoice {
        switch choice {
        case .yes: .yes
        case .maybe: .maybe
        case .no: .no
        case .hold: .noChange
        }
    }

    private func progress(_ session: InboxReviewSession) -> InboxReviewProgress {
        var session = session
        if session.summary == nil { session.updateSummary(freshnessCutoff: cutoff) }
        let queue = session.entries.prefix(session.queueCount)
        let metrics = session.metrics
        let s = session.summary
        let totals = InboxReviewTotals(
            yes: s?.yes ?? 0, no: s?.no ?? 0, maybe: s?.maybe ?? 0, held: s?.hold ?? 0,
            unclear: s?.unknown ?? 0, failed: s?.failed ?? 0, unavailable: s?.unavailable ?? 0, changed: s?.stale ?? 0,
            overlapsResolved: metrics.startingPairs.subtracting(metrics.remainingPairs).count,
            overlapsCreated: metrics.createdPairs.count, overlapsRemaining: metrics.remainingPairs.count,
            remainingQueue: s?.remainingQueueItems ?? 0, remainingInbox: s?.remainingInboxItems ?? 0,
            queueReviewed: s?.queueReviewed ?? false, inboxResolved: s?.inboxResolved ?? false,
            overlapsAreComplete: (s?.contextIsComplete ?? false) && (s?.attributionIsComplete ?? false))
        return InboxReviewProgress(
            sessionID: session.id, total: session.queueCount,
            reviewed: queue.filter { $0.outcome != nil && $0.outcome != .stale }.count,
            isFinished: session.cursor >= session.queueCount, hasUnclear: session.hasUnresolvedActions,
            currentKey: session.cursor < session.queueCount ? session.entries[session.cursor].sourceKeyHash : nil, totals: totals)
    }

    private func info(_ card: InboxReviewCard, session: InboxReviewSession) throws -> InboxReviewCardInfo {
        let context = card.context
        let event = context.focused.event
        let key = event.sourceKeyHash
        let choices = InboxCalendarContextBuilder.choices(for: context.focused, snapshot: context.snapshot)
        // The provider has to agree before any reply is offered.
        let replies: [ConflictChoice] = card.providerSnapshot == nil ? [] : choices.choices.compactMap {
            switch $0 {
            case .yes: .yes
            case .no: .no
            case .maybe: .maybe
            case .hold: nil
            }
        }
        let row = InboxAttentionQuery.evaluate(context.snapshot, freshnessCutoff: cutoff).rows.first { $0.item.event.sourceKeyHash == key }
        let entry = InboxScreenService.entry(
            event, observation: context.focused.observation, source: context.source, reasons: row?.reasons ?? [],
            changeIsUncertain: row?.changeTiming == .uncertain, overlapCount: context.focusedConflicts.count)
        let organizer = event.organizer.flatMap { $0.name ?? $0.emailAddress }
        let strip = InboxScreenService.contextEntries(context, focusedKey: key)
        let note: String
        if !replies.isEmpty { note = "" }
        else if choices.choices == [.hold] { note = ConflictResolutionService.reasonText(choices.unavailableReasons) }
        else { note = "Calopod could not check this event with the calendar. Hold it, or reply in the calendar app." }
        let previews = InboxScreenService.previews(for: replies, in: context, key: key)
        let account = InboxScreenService.accountLabel(context.source)
        let detail = InboxDetail(
            entry: entry, windowStart: context.visibleWindow.start, windowEnd: context.visibleWindow.end,
            context: strip, replies: replies, replyNote: note,
            account: account, connection: context.source.connectionLabel ?? context.source.provider, previews: previews,
            calendarEventID: context.source.provider == "eventkit" ? event.providerEventID : nil)
        let neighbors = context.conflictGroup.filter { $0.event.sourceKeyHash != key }.map { item in
            strip.first { $0.id == item.event.sourceKeyHash } ?? InboxContextEntry(
                id: item.event.sourceKeyHash, title: item.event.title ?? "Untitled event", calendarID: item.event.calendarBindingID,
                calendarName: context.snapshot.sources.first { $0.bindingID == item.event.calendarBindingID }?.calendarLabel ?? "Calendar",
                startsAt: item.event.startsAt, endsAt: item.event.endsAt, isFocused: false, overlapsFocused: true)
        }
        let source = context.source
        return InboxReviewCardInfo(
            detail: detail, position: min(session.cursor + 1, session.queueCount), total: session.queueCount,
            account: account, connection: detail.connection,
            isMacCalendar: source.provider == "eventkit", organizer: organizer,
            notification: card.providerSnapshot.map { Self.notification($0.notification, organizer: organizer) },
            previews: previews, neighbors: neighbors, card: card)
    }

    private static func notification(_ policy: RSVPNotificationPolicy, organizer: String?) -> String {
        let who = organizer ?? "the organizer"
        return switch policy {
        case .googleAllGuests: "Google may notify \(who) and the other guests."
        case .microsoftOrganizer: "Microsoft sends your response to \(who)."
        }
    }
}
#endif
