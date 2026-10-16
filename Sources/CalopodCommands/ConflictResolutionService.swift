#if os(macOS)
import CalopodDomain
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation

public enum ConflictChoice: String, CaseIterable, Sendable {
    case yes, maybe, no, noChange

    var inbox: InboxConflictChoice {
        switch self {
        case .yes: .yes
        case .maybe: .maybe
        case .no: .no
        case .noChange: .hold
        }
    }
}

public struct ConflictEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    public let calendarName: String
    public let provider: String
    public let response: String
    /// Replies only appear when the provider allows them.
    public let choices: [ConflictChoice]
    public let replyUnavailableReason: String?
}

public struct ConflictGroup: Identifiable, Equatable, Sendable {
    public var id: String { events.map(\.id).joined(separator: "|") }
    public let events: [ConflictEvent]
    public let overlapCount: Int
}

public struct ConflictBoard: Equatable, Sendable {
    public let groups: [ConflictGroup]
    /// False when a source is stale or partly read.
    public let isComplete: Bool
}

public struct ConflictSelection: Equatable, Sendable {
    public let eventID: String
    public let choice: ConflictChoice

    public init(eventID: String, choice: ConflictChoice) {
        self.eventID = eventID
        self.choice = choice
    }
}

public struct ConflictPreviewSummary: Equatable, Sendable {
    public struct Reply: Identifiable, Equatable, Sendable {
        public var id: String { eventID }
        public let eventID: String
        public let title: String
        public let choice: ConflictChoice
    }

    /// Sending a reply can notify the organizer.
    public let replies: [Reply]
    public let resolvedCount: Int
    public let remainingCount: Int
    public let createdCount: Int
    public let isComplete: Bool
}

public struct ConflictApplyReport: Equatable, Sendable {
    public enum Status: String, Sendable { case confirmed, failed, stale, unknown, unavailable }

    public struct Line: Identifiable, Equatable, Sendable {
        public var id: String { eventID }
        public let eventID: String
        public let title: String
        public let choice: ConflictChoice
        public let status: Status
        public let message: String
    }

    public let lines: [Line]
    public var confirmedCount: Int { lines.filter { $0.status == .confirmed }.count }
    public var allConfirmed: Bool { !lines.isEmpty && confirmedCount == lines.count }
}

public enum ConflictServiceError: Error, Equatable, Sendable {
    case nothingToApply
}

/// Backs the Mac conflicts screen. What counts as a conflict comes from the shared inbox core.
public struct ConflictResolutionService: Sendable {
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

    /// Groups overlapping events from the local copy. Never contacts a calendar.
    public func board() throws -> ConflictBoard {
        let snapshot = try makeRepository().inboxContextSnapshot()
        let result = InboxAttentionQuery.evaluate(
            snapshot,
            filter: InboxAttentionFilter(conflictsOnly: true, bindingIDs: Set(snapshot.sources.map(\.bindingID))),
            freshnessCutoff: freshnessCutoff
        )
        var seen = Set<String>()
        var groups: [ConflictGroup] = []
        for row in result.rows {
            let key = row.item.event.sourceKeyHash
            guard !seen.contains(key) else { continue }
            let keys = InboxConflictCalculator.group(containing: key, conflicts: result.analysis.conflicts)
            seen.formUnion(keys)
            let members = snapshot.events.filter { keys.contains($0.event.sourceKeyHash) }.sorted {
                ($0.event.startsAt, $0.event.sourceKeyHash) < ($1.event.startsAt, $1.event.sourceKeyHash)
            }
            groups.append(ConflictGroup(
                events: members.map { describe($0, in: snapshot) },
                overlapCount: result.analysis.conflicts.filter {
                    keys.contains($0.pair.first) && $0.isConfirmed
                }.count
            ))
        }
        groups.sort { ($0.events.first?.startsAt ?? .distantFuture) < ($1.events.first?.startsAt ?? .distantFuture) }
        return ConflictBoard(groups: groups, isComplete: result.analysis.isComplete)
    }

    /// Rereads the selected calendars under the sync lock. Throws `busy` if something else holds it.
    public func refresh() async throws {
        let state = try makeRepository()
        let lock = try ProcessLock.acquire(at: try makeLockURL())
        defer { withExtendedLifetime(lock) {} }
        _ = try await makeRefresh(state)()
    }

    /// Local only. Nothing is sent.
    public func preview(_ selections: [ConflictSelection]) throws -> ConflictPreviewSummary {
        let snapshot = try makeRepository().inboxContextSnapshot()
        let result = InboxAttentionQuery.evaluate(snapshot, freshnessCutoff: freshnessCutoff)
        let preview = try ConflictResolutionPlanner.preview(
            selections.map { ConflictDecision(sourceKeyHash: $0.eventID, choice: $0.choice.inbox) },
            in: snapshot,
            window: result.analysisWindow,
            freshnessCutoff: freshnessCutoff
        )
        let choiceByEvent = Dictionary(uniqueKeysWithValues: selections.map { ($0.eventID, $0.choice) })
        return ConflictPreviewSummary(
            replies: preview.changes.compactMap { change in
                guard let choice = choiceByEvent[change.sourceKeyHash] else { return nil }
                return .init(
                    eventID: change.sourceKeyHash,
                    title: title(of: change.sourceKeyHash, in: snapshot),
                    choice: choice
                )
            },
            resolvedCount: preview.resolved.count,
            remainingCount: preview.remaining.count,
            createdCount: preview.created.count,
            isComplete: preview.isComplete
        )
    }

    // MARK: Applying

    /// Sends replies one at a time, each revalidated just before it goes. A changed event is skipped and reported.
    public func apply(_ selections: [ConflictSelection]) async throws -> ConflictApplyReport {
        let replies = selections.filter { $0.choice != .noChange }
        guard !replies.isEmpty else { throw ConflictServiceError.nothingToApply }

        let state = try makeRepository()
        let snapshot = try state.inboxContextSnapshot()
        let cutoff = freshnessCutoff
        let queue = InboxAttentionQuery.evaluate(
            snapshot,
            filter: InboxAttentionFilter(conflictsOnly: true, bindingIDs: Set(snapshot.sources.map(\.bindingID))),
            freshnessCutoff: cutoff
        )
        // Fails before anything is sent if a choice isn't allowed.
        _ = try ConflictResolutionPlanner.preview(
            selections.map { ConflictDecision(sourceKeyHash: $0.eventID, choice: $0.choice.inbox) },
            in: snapshot, window: queue.analysisWindow, freshnessCutoff: cutoff
        )

        let controller = InboxReviewSessionController(state: state, lockURL: try makeLockURL())
        let refresh = makeRefresh(state)
        var session = try controller.start(
            filter: InboxAttentionFilter(conflictsOnly: true, bindingIDs: Set(snapshot.sources.map(\.bindingID))),
            metricsWindow: queue.analysisWindow ?? SyncWindow(start: now(), end: now().addingTimeInterval(1)),
            freshnessCutoff: cutoff
        )
        let queued = session.entries.prefix(session.queueCount).map(\.sourceKeyHash)

        var lines: [ConflictApplyReport.Line] = []
        for selection in replies {
            let key = selection.eventID
            let name = title(of: key, in: snapshot)
            func line(_ status: ConflictApplyReport.Status, _ message: String) -> ConflictApplyReport.Line {
                .init(eventID: key, title: name, choice: selection.choice, status: status, message: message)
            }
            do {
                let group = InboxConflictCalculator.group(containing: key, conflicts: queue.analysis.conflicts)
                let origin = queued.contains(key) ? nil : queued.first(where: group.contains)
                guard let card = try await controller.card(
                    sessionID: session.id, sourceKeyHash: key, conflictFromKey: origin,
                    freshnessCutoff: cutoff, refresh: refresh, provider: provider
                ) else {
                    lines.append(line(.failed, "Calopod could not open this event. Nothing was sent."))
                    continue
                }
                session = try await controller.decide(
                    selection.choice.inbox, card: card,
                    freshnessCutoff: cutoff, refresh: refresh, provider: provider
                )
                let outcome = session.entries.first(where: { $0.sourceKeyHash == key })?.outcome
                lines.append(Self.line(for: outcome, make: line))
            } catch {
                lines.append(Self.failureLine(error, make: line))
            }
        }
        return ConflictApplyReport(lines: lines)
    }

    // MARK: Helpers

    static func line(
        for outcome: InboxReviewOutcome?,
        make: (ConflictApplyReport.Status, String) -> ConflictApplyReport.Line
    ) -> ConflictApplyReport.Line {
        switch outcome {
        case .confirmed: make(.confirmed, "Your reply was recorded.")
        case .stale: make(.stale, "The event changed first, so nothing was sent. Review it again.")
        case .unavailable: make(.unavailable, "This reply isn't available any more. Nothing was sent.")
        case .failed: make(.failed, "The calendar rejected the reply. Nothing changed.")
        default: make(.unknown, "Calopod could not confirm the reply. Check the calendar before trying again.")
        }
    }

    static func failureLine(
        _ error: Error,
        make: (ConflictApplyReport.Status, String) -> ConflictApplyReport.Line
    ) -> ConflictApplyReport.Line {
        switch error {
        case InboxReviewSessionError.freshDecisionRequired,
             InboxCalendarContextError.previewChanged,
             InboxCalendarContextError.eventUnavailable:
            make(.stale, "The event changed since you looked, so nothing was sent. Review it again.")
        case InboxCalendarContextError.actionUnavailable, InboxReviewSessionError.itemNotQueued:
            make(.unavailable, "This reply isn't available. Nothing was sent.")
        case CalopodRuntimeError.busy:
            make(.failed, "A sync is running. Try again in a moment. Nothing was sent.")
        default:
            make(.failed, "Calopod could not send this reply. Nothing was sent.")
        }
    }

    private func title(of key: String, in snapshot: InboxContextSnapshot) -> String {
        let title = snapshot.events.first(where: { $0.event.sourceKeyHash == key })?.event.title
        return (title?.isEmpty == false ? title : nil) ?? "Untitled event"
    }

    private func describe(_ item: InboxContextEvent, in snapshot: InboxContextSnapshot) -> ConflictEvent {
        let event = item.event
        let source = snapshot.sources.first { $0.bindingID == event.calendarBindingID }
        let choices = InboxCalendarContextBuilder.choices(for: item, snapshot: snapshot)
        let replies = choices.choices.compactMap { choice -> ConflictChoice? in
            switch choice {
            case .yes: .yes
            case .maybe: .maybe
            case .no: .no
            case .hold: nil
            }
        }
        return ConflictEvent(
            id: event.sourceKeyHash,
            title: title(of: event.sourceKeyHash, in: snapshot),
            startsAt: event.startsAt,
            endsAt: event.endsAt,
            isAllDay: event.isAllDay,
            calendarName: source?.calendarLabel ?? source?.connectionLabel ?? "Unknown calendar",
            provider: source?.provider ?? "unknown",
            response: event.currentUserResponse.state.rawValue,
            choices: replies + [.noChange],
            replyUnavailableReason: replies.isEmpty ? Self.reasonText(choices.unavailableReasons) : nil
        )
    }

    static func reasonText(_ reasons: [RSVPUnavailableReason]) -> String {
        if reasons.contains(.providerReadOnly) {
            return "Calopod reads this calendar through your Mac. Reply in the Calendar app."
        }
        if reasons.contains(.notAnInvitation) {
            return "You organize this event or it isn't an invitation."
        }
        if reasons.contains(.identityUnverified) || reasons.contains(.permissionUnverified) {
            return "Calopod can't confirm this calendar is your own."
        }
        if reasons.contains(.managedMirror) {
            return "This is a copy Calopod made."
        }
        return "Replies aren't supported for this event."
    }
}
#endif
