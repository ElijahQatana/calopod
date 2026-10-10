import ArgumentParser
import CalopodDomain
import CalopodProviders
import CalopodRuntime
import CalopodStore
import CalopodSync
@testable import CalopodCommands
import Foundation
import Testing

@Suite("Inbox review transcripts")
struct InboxReviewTerminalTests {
    @Test func completeFlowAndInvalidInput() async throws {
        let f = try TranscriptFixture(count: 4)
        defer { f.remove() }
        let (session, text) = try await f.run(["invalid", "Y", "y", "n", "m", "h"])
        #expect(session.summary?.yes == 1 && session.summary?.no == 1 && session.summary?.maybe == 1 && session.summary?.hold == 1)
        #expect(session.summary?.remainingQueueItems == 0)
        #expect(text.contains("Enter one available choice"))
        #expect(text.contains("may notify the organizer"))
        #expect(text.contains("Tiny squid"))
        #expect(text.contains("Queue reviewed. Inbox still has outstanding items."))
        #expect(await f.remote.writes == 3)
    }

    @Test func emptyAndUnavailable() async throws {
        for count in [0, 1] {
            let f = try TranscriptFixture(count: count, backend: "eventkit")
            defer { f.remove() }
            let (session, text) = try await f.run(["y", "h"])
            #expect(session.summary?.hold == count)
            #expect(await f.remote.writes == 0)
            #expect(text.contains("No responses sent"))
            if count == 1 {
                #expect(text.contains("RSVP unavailable"))
                #expect(!text.contains("[y] Yes"))
            }
        }
    }

    @Test func cancellationAndResumeDoNotRepeatHoldsOrMaybe() async throws {
        let f = try TranscriptFixture(count: 3)
        defer { f.remove() }
        let (paused, text) = try await f.run(["h", "m"])
        #expect(text.contains("--resume"))
        #expect(paused.cursor == 2)
        let resumed = try await f.controller.resume(id: paused.id, freshnessCutoff: f.cutoff, refresh: f.refresh, provider: f.provider)
        let (done, final) = try await f.run(["n"], session: resumed)
        #expect(done.summary?.hold == 1 && done.summary?.maybe == 1 && done.summary?.no == 1)
        #expect(await f.remote.writes == 2)
        #expect(!final.contains("Example 0\n"))
    }

    @Test func conflictNavigationReturnsAndReplacesTotals() async throws {
        let f = try TranscriptFixture(count: 2, overlapping: true)
        defer { f.remove() }
        let (done, text) = try await f.run(["g1", "y", "n", "m"])
        #expect(text.contains("[b] Back to queue"))
        #expect(text.contains("Yes overlaps Example"))
        #expect(text.contains("1000.0 seconds"))
        #expect(done.summary?.yes == 1 && done.summary?.no == 1)
        #expect(done.summary?.maybe == 0)
        #expect(done.summary?.remainingConflicts == 0)
        #expect(await f.remote.writes == 2)
    }

    @Test func failureCanHoldAndUnknownMustReconcile() async throws {
        for mode in [TranscriptRemote.Mode.failed, .unknown, .staleOnce, .previewFailed] {
            let f = try TranscriptFixture(count: 1)
            defer { f.remove() }
            await f.remote.setMode(mode)
            let (done, text) = try await f.run(["y", "h"])
            #expect(done.summary?.yes == 0)
            if mode == .unknown {
                #expect(done.summary?.unknown == 1)
                #expect(text.contains("--resume"))
                #expect(!text.contains("Tiny squid"))
            } else { #expect(done.summary?.hold == 1) }
            if mode == .staleOnce { #expect(text.contains("Event changed")) }
            if mode == .previewFailed { #expect(await f.remote.writes == 0) }
        }
    }

    @Test func changedRevisionRequiresFreshInput() async throws {
        let f = try TranscriptFixture(count: 1)
        defer { f.remove() }
        var changed = false
        var transcript = ""
        var inputs = ["y", "h"]
        let terminal = f.terminal(read: {
            if !changed { changed = true; try! f.apply(title: "Revised example") }
            return inputs.isEmpty ? nil : inputs.removeFirst()
        }, write: { transcript += $0 + "\n" })
        let done = try await terminal.run(f.start())
        #expect(transcript.contains("Read the refreshed card"))
        #expect(transcript.contains("Revised example"))
        #expect(done.summary?.hold == 1)
        #expect(await f.remote.writes == 0)
    }

    @Test func configFiltersAndFullDetails() async throws {
        let f = try TranscriptFixture(count: 2, overlapping: true)
        defer { f.remove() }
        let config = try InboxConfigCommand.parse(["--context-before-minutes", "10", "--context-after-minutes", "20"])
        let settings = try config.context.resolve(f.state.inboxContextSettings())
        try f.state.saveInboxContextSettings(settings)
        #expect(try f.state.inboxContextSettings() == settings)
        #expect(throws: (any Error).self) { try InboxConfigCommand.parse(["--context-before-minutes", "-1"]).context.resolve(settings) }
        let excluded = try f.controller.start(filter: InboxAttentionFilter(bindingIDs: ["other"]), metricsWindow: f.window, freshnessCutoff: f.cutoff)
        #expect(excluded.queueCount == 0)
        let start = try f.controller.start(filter: InboxAttentionFilter(conflictsOnly: true), settings: settings, metricsWindow: f.window, freshnessCutoff: f.cutoff)
        #expect(start.queueCount == 2)
        let (_, text) = try await f.run(["h", "h"], session: start)
        for detail in ["Organizer: Taylor Example", "taylor@example.com", "Location: Example room", "Details: Example notes", "https://example.com/meeting", "GMT", "Source: Example / Calendar", "Remaining conflicts: 1"] {
            #expect(text.contains(detail))
        }
        let command = try InboxReviewCommand.parse(["--exclude-maybe", "--day", "2026-11-05", "--timezone", "UTC", "--connection", "connection", "--calendar", "calendar", "--conflicts", "--context-before-minutes", "15"])
        #expect(command.options.excludeMaybe && command.options.conflicts)
        #expect(command.context.contextBeforeMinutes == 15)
        #expect(throws: (any Error).self) { try InboxReviewCommand.parse(["--resume", "--exclude-maybe"]) }
    }

    @Test func artTiersAndSafeNarrowOutput() {
        for (count, expected) in [(0, "No responses sent"), (1, "Tiny squid"), (5, "Tiny squid"), (6, "Party squid"), (20, "Party squid"), (21, "kraken")] {
            #expect(InboxReviewTerminal.celebration(count, decoration: true, width: 80).contains(expected))
        }
        #expect(!InboxReviewTerminal.celebration(21, decoration: false, width: 80).contains("kraken"))
        #expect(!InboxReviewTerminal.celebration(21, decoration: true, width: 12).contains("kraken"))
        let safe = InboxReviewTerminal.safe("Example\u{1b}[2J\u{07}\u{202e}界界 long title", width: 12)
        #expect(!safe.contains("\u{1b}") && !safe.contains("\u{07}") && !safe.contains("\u{202e}"))
        #expect(safe.components(separatedBy: "\n").allSatisfy { $0.count <= 12 })
    }

    @Test func noninteractiveRefusesBeforeStateOrProviders() async throws {
        let command = try InboxReviewCommand.parse(["--format", "json"])
        await #expect(throws: (any Error).self) { try await command.run() }
    }
}

private struct TranscriptFixture {
    let root: URL
    let state: LocalStateRepository
    let remote: TranscriptRemote
    let count: Int
    let overlapping: Bool
    var cutoff: Date { Date().addingTimeInterval(-3600) }
    var window: SyncWindow { try! SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 200_000)) }
    var controller: InboxReviewSessionController { InboxReviewSessionController(state: state, lockURL: root.appendingPathComponent("review.lock")) }
    var refresh: InboxReviewSessionController.Refresh { { try state.inboxContextSnapshot() } }
    var provider: InboxReviewSessionController.Provider { { _ in remote } }
    init(count: Int, overlapping: Bool = false, backend: String = "google") throws {
        self.count = count; self.overlapping = overlapping
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        state = LocalStateRepository(database: try CalopodDatabase(path: root.appendingPathComponent("state.sqlite").path))
        remote = TranscriptRemote(state: state)
        try state.saveConnection(StoredConnection(id: "connection", configurationID: "config", provider: backend, displayLabel: "Example", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "connection", bindings: [StoredCalendarBinding(id: "calendar", connectionID: "connection", providerCalendarID: "primary", displayLabel: "Calendar", isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser)])
        try apply()
    }
    func apply(title: String? = nil) throws {
        let events = (0..<count).map { index in
            StoredNormalizedInstance(sourceKeyHash: "key\(index)", connectionID: "connection", calendarBindingID: "calendar", providerEventID: "key\(index)", recurrenceID: nil,
                startsAt: Date(timeIntervalSince1970: overlapping ? 10_000 : 10_000 + Double(index) * 20_000),
                endsAt: Date(timeIntervalSince1970: overlapping ? 11_000 : 11_000 + Double(index) * 20_000),
                isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false, title: title ?? "Example \(index)", contentFingerprint: "example", providerUpdatedAt: nil, location: "Example room", notes: "Example notes", url: "https://example.com/meeting", organizer: EventParticipant(name: "Taylor Example", emailAddress: "taylor@example.com"),
                currentUserResponse: EventResponse(state: .needsResponse, evidence: .googleSelf, actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
        }
        try state.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar", windowStart: window.start, windowEnd: window.end, instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
    }
    func start() throws -> InboxReviewSession { try controller.start(metricsWindow: window, freshnessCutoff: cutoff) }
    func terminal(read: @escaping () -> String?, write: @escaping (String) -> Void) -> InboxReviewTerminal {
        InboxReviewTerminal(controller: controller, refresh: refresh, provider: provider, read: read, write: write, timezone: TimeZone(secondsFromGMT: 0)!)
    }
    func run(_ inputs: [String], session: InboxReviewSession? = nil) async throws -> (InboxReviewSession, String) {
        var lines = inputs, text = ""
        let terminal = terminal(read: { lines.isEmpty ? nil : lines.removeFirst() }, write: { text += $0 + "\n" })
        let result = try await terminal.run(session ?? start())
        return (result, text)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor TranscriptRemote: RSVPActionProvider {
    enum Mode { case confirmed, failed, unknown, staleOnce, previewFailed }
    let state: LocalStateRepository
    var writes = 0
    var mode = Mode.confirmed
    init(state: LocalStateRepository) { self.state = state }
    func setMode(_ mode: Mode) { self.mode = mode }
    func rsvpSnapshot(target: RSVPTarget) async throws -> RSVPEventSnapshot {
        if mode == .previewFailed { throw RSVPActionError.rejected }
        let local = try #require(try state.inboxContextSnapshot().events.first { $0.event.sourceKeyHash == target.eventID }?.event)
        let event = ProviderEvent(provider: "google", connectionID: target.connectionID, calendarID: target.calendarID, eventID: target.eventID, seriesID: nil, originalStart: nil,
            start: local.startsAt, end: local.endsAt, isAllDay: local.isAllDay, availability: .busy, isCancelled: false, isPrivate: false,
            title: local.title, updatedAt: nil, location: local.location, notes: local.notes, url: local.url, organizer: local.organizer, responseMetadata: local.currentUserResponse)
        return RSVPEventSnapshot(target: target, event: event, version: "v1", capability: RSVPActionCapability(supportedScopes: [.occurrence]), notification: .googleAllGuests, concurrency: .conditionalUpdate)
    }
    func submitRSVP(_ intent: RSVPActionIntent) async throws {
        if mode == .staleOnce { mode = .confirmed; throw RSVPActionError.stale }
        writes += 1
        if mode == .failed { throw RSVPActionError.rejected }
        if mode == .unknown { throw RSVPActionError.uncertain }
        var events = try state.inboxContextSnapshot().events.map(\.event)
        let index = try #require(events.firstIndex { $0.sourceKeyHash == intent.target.eventID })
        let old = events[index]
        events[index] = StoredNormalizedInstance(sourceKeyHash: old.sourceKeyHash, connectionID: old.connectionID,
            calendarBindingID: old.calendarBindingID, providerEventID: old.providerEventID, recurrenceID: old.recurrenceID,
            startsAt: old.startsAt, endsAt: old.endsAt, isAllDay: old.isAllDay, availability: old.availability,
            isCancelled: old.isCancelled, isPrivate: old.isPrivate, title: old.title,
            contentFingerprint: old.contentFingerprint, providerUpdatedAt: old.providerUpdatedAt,
            location: old.location, notes: old.notes, url: old.url, organizer: old.organizer,
            currentUserResponse: EventResponse(state: intent.decision.responseState, evidence: .googleSelf,
                actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
        try state.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar", windowStart: Date(timeIntervalSince1970: 0), windowEnd: Date(timeIntervalSince1970: 200_000), instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
    }
    func reconcileRSVP(_ record: RSVPActionRecord) async throws -> RSVPActionOutcome {
        if mode == .unknown { return RSVPActionOutcome(status: .unknown, issue: .uncertain) }
        return try await RSVPReadback.outcome(record, snapshot: rsvpSnapshot(target: record.intent.target))
    }
}
