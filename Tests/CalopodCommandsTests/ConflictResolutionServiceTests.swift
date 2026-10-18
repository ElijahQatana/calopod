#if os(macOS)
import CalopodDomain
import CalopodProviders
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation
import Testing

@testable import CalopodCommands

@Suite("Mac conflict resolution service")
struct ConflictResolutionServiceTests {
    @Test("Overlapping events form one group with a no-change choice for each")
    func boardGroupsOverlaps() throws {
        let f = try ConflictFixture(keys: ["a", "b"])
        defer { f.remove() }

        let board = try f.service.board()

        #expect(board.groups.count == 1)
        let group = try #require(board.groups.first)
        #expect(group.events.map(\.id) == ["a", "b"])
        #expect(group.overlapCount == 1)
        for event in group.events {
            #expect(event.choices == [.yes, .no, .maybe, .noChange])
            #expect(event.replyUnavailableReason == nil)
        }
    }

    @Test("A read-only calendar offers only no change, with a reason")
    func readOnlyCalendar() throws {
        let f = try ConflictFixture(keys: ["a", "b"], provider: "eventkit")
        defer { f.remove() }

        let event = try #require(try f.service.board().groups.first?.events.first)

        #expect(event.choices == [.noChange])
        #expect(event.replyUnavailableReason?.contains("Calendar app") == true)
    }

    @Test("The preview combines choices and sends nothing")
    func previewIsLocal() async throws {
        let f = try ConflictFixture(keys: ["a", "b"])
        defer { f.remove() }

        let preview = try f.service.preview([
            ConflictSelection(eventID: "a", choice: .no),
            ConflictSelection(eventID: "b", choice: .noChange),
        ])

        #expect(preview.replies.map(\.eventID) == ["a"])
        #expect(preview.resolvedCount == 1)
        #expect(preview.remainingCount == 0)
        #expect(preview.createdCount == 0)
        #expect(await f.remote.writes == 0)
    }

    @Test("Applying a reply sends it once and the conflict disappears")
    func applyConfirms() async throws {
        let f = try ConflictFixture(keys: ["a", "b"])
        defer { f.remove() }

        let report = try await f.service.apply([ConflictSelection(eventID: "a", choice: .no)])

        #expect(report.allConfirmed)
        #expect(await f.remote.writes == 1)
        #expect(try f.service.board().groups.isEmpty)
    }

    @Test("A rejected reply is reported as failed and the conflict stays")
    func applyFailure() async throws {
        let f = try ConflictFixture(keys: ["a", "b"])
        defer { f.remove() }
        await f.remote.setMode(.failed)

        let report = try await f.service.apply([ConflictSelection(eventID: "a", choice: .no)])

        #expect(report.lines.map(\.status) == [.failed])
        #expect(report.confirmedCount == 0)
        #expect(try f.service.board().groups.count == 1)
    }

    @Test("One stale reply does not stop or undo the others")
    func partialSuccess() async throws {
        let f = try ConflictFixture(keys: ["a", "b"])
        defer { f.remove() }
        await f.remote.setMode(.staleOnce)

        let report = try await f.service.apply([
            ConflictSelection(eventID: "a", choice: .no),
            ConflictSelection(eventID: "b", choice: .maybe),
        ])

        #expect(report.lines.map(\.status) == [.stale, .confirmed])
        #expect(report.confirmedCount == 1)
        #expect(!report.allConfirmed)
    }

    @Test("Choosing no change for everything is refused rather than silently doing nothing")
    func nothingToApply() async throws {
        let f = try ConflictFixture(keys: ["a", "b"])
        defer { f.remove() }

        await #expect(throws: ConflictServiceError.nothingToApply) {
            _ = try await f.service.apply([ConflictSelection(eventID: "a", choice: .noChange)])
        }
        #expect(await f.remote.writes == 0)
    }

    @Test("A reply the event doesn't allow is rejected before anything is sent")
    func unavailableReplyIsRejected() async throws {
        let f = try ConflictFixture(keys: ["a", "b"], provider: "eventkit")
        defer { f.remove() }

        await #expect(throws: ConflictResolutionError.choiceUnavailable("a")) {
            _ = try await f.service.apply([ConflictSelection(eventID: "a", choice: .no)])
        }
        #expect(await f.remote.writes == 0)
    }
}

private struct ConflictFixture {
    let root: URL
    let state: LocalStateRepository
    let remote: ConflictRemote
    let service: ConflictResolutionService

    init(keys: [String], provider: String = "google") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = LocalStateRepository(database: try CalopodDatabase(path: root.appendingPathComponent("state.sqlite").path))
        self.state = state
        let remote = ConflictRemote(state: state)
        self.remote = remote
        try state.saveConnection(StoredConnection(
            id: "connection", configurationID: "config", provider: provider,
            displayLabel: "Example", isEnabled: true
        ))
        try state.replaceCalendarBindings(connectionID: "connection", bindings: [
            StoredCalendarBinding(
                id: "calendar", connectionID: "connection", providerCalendarID: "primary",
                displayLabel: "Calendar", isSelected: true, isReadOnly: false,
                responseIdentityScope: .authenticatedUser
            ),
        ])
        let events = keys.map { key in
            StoredNormalizedInstance(
                sourceKeyHash: key, connectionID: "connection", calendarBindingID: "calendar",
                providerEventID: key, recurrenceID: nil,
                startsAt: Date(timeIntervalSince1970: 10_000), endsAt: Date(timeIntervalSince1970: 11_000),
                isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false,
                title: "Event \(key)", contentFingerprint: "example", providerUpdatedAt: nil,
                currentUserResponse: EventResponse(
                    state: .needsResponse, evidence: .googleSelf,
                    actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])
                )
            )
        }
        try state.applyEventRefresh(
            connectionID: "connection", calendarBindingID: "calendar",
            windowStart: Date(timeIntervalSince1970: 0), windowEnd: Date(timeIntervalSince1970: 200_000),
            instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: []
        )
        let lock = root.appendingPathComponent("review.lock")
        service = ConflictResolutionService(
            makeRepository: { state },
            makeLockURL: { lock },
            makeRefresh: { state in { try state.inboxContextSnapshot() } },
            provider: { _ in remote },
            now: { Date(timeIntervalSince1970: 5_000) }
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor ConflictRemote: RSVPActionProvider {
    enum Mode { case confirmed, failed, staleOnce }
    let state: LocalStateRepository
    var writes = 0
    var mode = Mode.confirmed
    init(state: LocalStateRepository) { self.state = state }
    func setMode(_ mode: Mode) { self.mode = mode }

    func rsvpSnapshot(target: RSVPTarget) async throws -> RSVPEventSnapshot {
        let local = try #require(try state.inboxContextSnapshot().events.first { $0.event.sourceKeyHash == target.eventID }?.event)
        let event = ProviderEvent(
            provider: "google", connectionID: target.connectionID, calendarID: target.calendarID,
            eventID: target.eventID, seriesID: nil, originalStart: nil, start: local.startsAt, end: local.endsAt,
            isAllDay: local.isAllDay, availability: .busy, isCancelled: false, isPrivate: false,
            title: local.title, updatedAt: nil, location: local.location, notes: local.notes, url: local.url,
            organizer: local.organizer, responseMetadata: local.currentUserResponse
        )
        return RSVPEventSnapshot(
            target: target, event: event, version: "v1",
            capability: RSVPActionCapability(supportedScopes: [.occurrence]),
            notification: .googleAllGuests, concurrency: .conditionalUpdate
        )
    }

    func submitRSVP(_ intent: RSVPActionIntent) async throws {
        if mode == .staleOnce { mode = .confirmed; throw RSVPActionError.stale }
        writes += 1
        if mode == .failed { throw RSVPActionError.rejected }
        var events = try state.inboxContextSnapshot().events.map(\.event)
        let index = try #require(events.firstIndex { $0.sourceKeyHash == intent.target.eventID })
        let old = events[index]
        events[index] = StoredNormalizedInstance(
            sourceKeyHash: old.sourceKeyHash, connectionID: old.connectionID,
            calendarBindingID: old.calendarBindingID, providerEventID: old.providerEventID,
            recurrenceID: old.recurrenceID, startsAt: old.startsAt, endsAt: old.endsAt,
            isAllDay: old.isAllDay, availability: old.availability, isCancelled: old.isCancelled,
            isPrivate: old.isPrivate, title: old.title, contentFingerprint: old.contentFingerprint,
            providerUpdatedAt: old.providerUpdatedAt, location: old.location, notes: old.notes,
            url: old.url, organizer: old.organizer,
            currentUserResponse: EventResponse(
                state: intent.decision.responseState, evidence: .googleSelf,
                actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])
            )
        )
        try state.applyEventRefresh(
            connectionID: "connection", calendarBindingID: "calendar",
            windowStart: Date(timeIntervalSince1970: 0), windowEnd: Date(timeIntervalSince1970: 200_000),
            instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: []
        )
    }

    func reconcileRSVP(_ record: RSVPActionRecord) async throws -> RSVPActionOutcome {
        try await RSVPReadback.outcome(record, snapshot: rsvpSnapshot(target: record.intent.target))
    }
}
#endif

#if os(macOS)
@Suite("Mac conflict refresh")
struct ConflictRefreshTests {
    private func service(
        root: URL,
        state: LocalStateRepository,
        refreshCalls: RefreshCounter
    ) -> ConflictResolutionService {
        let lock = root.appendingPathComponent("review.lock")
        return ConflictResolutionService(
            makeRepository: { state },
            makeLockURL: { lock },
            makeRefresh: { state in
                {
                    refreshCalls.increment()
                    return try state.inboxContextSnapshot()
                }
            },
            provider: { _ in throw RSVPActionError.unavailable(.unsupported) }
        )
    }

    private func makeState() throws -> (URL, LocalStateRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = LocalStateRepository(
            database: try CalopodDatabase(path: root.appendingPathComponent("state.sqlite").path)
        )
        return (root, state)
    }

    @Test("Refresh re-reads the sources once and releases the lock")
    func refreshReadsOnce() async throws {
        let (root, state) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = RefreshCounter()
        let service = service(root: root, state: state, refreshCalls: calls)

        try await service.refresh()

        #expect(calls.count == 1)
        let again = try ProcessLock.acquire(at: root.appendingPathComponent("review.lock"))
        withExtendedLifetime(again) {}
    }

    @Test("Refresh refuses to run while a sync holds the lock")
    func refreshWaitsForSync() async throws {
        let (root, state) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = RefreshCounter()
        let service = service(root: root, state: state, refreshCalls: calls)
        let held = try ProcessLock.acquire(at: root.appendingPathComponent("review.lock"))
        defer { withExtendedLifetime(held) {} }

        await #expect(throws: CalopodRuntimeError.busy) { try await service.refresh() }
        #expect(calls.count == 0)
    }
}

final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
#endif
