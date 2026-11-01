import ArgumentParser
import CalopodDomain
import CalopodProviders
import CalopodRuntime
import CalopodStore
import CalopodSync
@testable import CalopodCommands
import Foundation
import Testing
#if os(macOS)
import Darwin
#endif

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

    @Test func snoozeKeyPutsItemAwayWithoutSending() async throws {
        let f = try TranscriptFixture(count: 3)
        defer { f.remove() }
        let (session, text) = try await f.run(["z", "t", "z", "2001-01-01", "h", "y"])
        #expect(session.summary?.snoozed == 1 && session.summary?.hold == 1 && session.summary?.yes == 1)
        #expect(text.contains("[z] Snooze"))
        #expect(text.contains("Not snoozed"))
        #expect(await f.remote.writes == 1)
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
                #expect(text.contains("Open in Calendar"))
                #expect(!text.contains("[y] Yes"))
            }
        }
    }

    @Test func openInCalendarHintIsOnlyForTheMacCalendar() async throws {
        let f = try TranscriptFixture(count: 1)
        defer { f.remove() }
        let (_, text) = try await f.run(["h"])
        #expect(!text.contains("Open in Calendar"))
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
        let (done, text) = try await f.run(["g1", "y", "g1", "m", "n"])
        #expect(text.contains("[b] Back to queue"))
        #expect(text.contains("Yes overlaps Example"))
        #expect(text.contains("1000.0 seconds"))
        #expect(done.summary?.yes == 0 && done.summary?.no == 1)
        #expect(done.summary?.maybe == 1)
        #expect(done.summary?.remainingConflicts == 0)
        #expect(await f.remote.writes == 3)
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

    @Test func failedFinalExitKeepsFailureWithoutOfferingAnUnavailableResume() async throws {
        let f = try TranscriptFixture(count: 1)
        defer { f.remove() }
        await f.remote.setMode(.failed)
        let (done, text) = try await f.run(["y", "q"])
        #expect(done.summary?.failed == 1 && done.summary?.yes == 0)
        #expect(text.contains("Start calopod inbox review for remaining items"))
        #expect(!text.contains("--resume"))
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
        for detail in ["Organizer: Taylor Example", "taylor@example.com", "Location: Example room", "Details: Example notes", "https://example.com/meeting", "GMT", "Source: Example / Calendar", "Overlapping pairs left: 1"] {
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

    @Test func offscreenOverlapUsesFullInterval() async throws {
        let f = try TranscriptFixture(count: 2, overlapping: true)
        defer { f.remove() }
        try f.replace("key1", start: 10_800, end: 11_800)
        let session = try f.controller.start(settings: InboxContextSettings(beforeMinutes: 0, afterMinutes: 1),
            metricsWindow: f.window, freshnessCutoff: f.cutoff)
        let card = try #require(try await f.controller.card(sessionID: session.id, freshnessCutoff: f.cutoff, refresh: f.refresh, provider: f.provider))
        #expect(card.context.rows.count == 1)
        #expect(card.context.focusedConflicts.first?.overlap.start == Date(timeIntervalSince1970: 10_800))
        let (_, text) = try await f.run(["h", "h"], session: session)
        #expect(text.contains("Yes overlaps Example 1"))
        #expect(text.contains("200.0 seconds"))
        #expect(text.contains("[g1] Review Example 1"))
    }

    @Test func filtersKeepContextAndSavedTimezone() async throws {
        let f = try TranscriptFixture(count: 2, overlapping: true)
        defer { f.remove() }
        try f.replace("key1", response: .tentative)
        let session = try f.controller.start(filter: InboxAttentionFilter(window: f.window, excludeMaybe: true,
            conflictsOnly: true, bindingIDs: ["calendar"]), metricsWindow: f.window, freshnessCutoff: f.cutoff,
            displayTimeZoneIdentifier: "America/New_York")
        #expect(session.entries.map(\.sourceKeyHash) == ["key0"])
        let (_, text) = try await f.run([], session: session)
        #expect(text.contains("Maybe excluded; conflicts only"))
        #expect(text.contains("Example 1"))
        let resumed = try await f.controller.resume(id: session.id, freshnessCutoff: f.cutoff, refresh: f.refresh, provider: f.provider)
        #expect(resumed.displayTimeZoneIdentifier == "America/New_York")
        #expect(resumed.filter == session.filter)
        let outside = try f.controller.start(filter: InboxAttentionFilter(window: SyncWindow(start: Date(timeIntervalSince1970: 20_000), end: Date(timeIntervalSince1970: 21_000))), metricsWindow: f.window, freshnessCutoff: f.cutoff)
        #expect(outside.queueCount == 0)
    }

    @Test func narrowCardsEscapeContentAndKeepIncompleteEvidence() async throws {
        let f = try TranscriptFixture(count: 1)
        defer { f.remove() }
        try f.apply(title: "Example\u{1b}[2J\u{07}\u{202e} title")
        try f.state.markConnectionStale(connectionID: "connection", errorCode: "temporary")
        var inputs = ["h"], text = ""
        var terminal = f.terminal(read: { inputs.isEmpty ? nil : inputs.removeFirst() }, write: { text += $0 + "\n" })
        terminal.width = 24; terminal.decoration = false
        let done = try await terminal.run(f.start())
        #expect(!text.contains("\u{1b}") && !text.contains("\u{07}") && !text.contains("\u{202e}"))
        #expect(text.split(separator: "\n").allSatisfy { $0.count <= 24 })
        #expect(text.contains("incomplete"))
        #expect(done.summary?.contextIsComplete == false)
    }

    @Test func broaderScopeAndProviderCapabilityDoNotOfferResponses() async throws {
        for mode in [TranscriptRemote.Mode.seriesOnly, .differentScope] {
            let f = try TranscriptFixture(count: 1)
            defer { f.remove() }
            await f.remote.setMode(mode)
            let (done, text) = try await f.run(["h"])
            #expect(!text.contains("[y] Yes"))
            #expect(done.summary?.hold == 1)
            #expect(await f.remote.writes == 0)
        }
    }

    @Test func introducedConflictStaysCountedAfterResolution() async throws {
        let f = try TranscriptFixture(count: 2, overlapping: true)
        defer { f.remove() }
        try f.replace("key0", response: .declined)
        try f.replace("key0", title: "Changed invitation")
        let (done, text) = try await f.run(["y", "n"])
        #expect(done.summary?.yes == 1 && done.summary?.no == 1)
        #expect(done.summary?.createdConflicts == 1)
        #expect(done.summary?.remainingConflicts == 0)
        #expect(text.contains("New overlapping pairs: 1"))
    }

    @Test func completeSessionsSelectArtFromConfirmedTotals() async throws {
        for (count, expected) in [(6, "Party squid"), (21, "kraken")] {
            let f = try TranscriptFixture(count: count)
            defer { f.remove() }
            let (done, text) = try await f.run(Array(repeating: "n", count: count))
            #expect(done.summary?.no == count)
            #expect(text.contains(expected))
        }
    }

    #if os(macOS)
    @Test(arguments: [false, true]) func terminalEOFAndInterruptSaveProgress(interrupt: Bool) throws {
        let f = try TranscriptFixture(count: 1, backend: "ics", base: 4_000_000_000)
        defer { f.remove() }
        var master: Int32 = 0, slave: Int32 = 0
        #expect(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        let process = Process()
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = package.appendingPathComponent(".build/debug/calopod")
        process.arguments = ["inbox", "review", "--no-decoration"]
        var environment = ProcessInfo.processInfo.environment
        environment["CALOPOD_STATE_PATH"] = f.root.appendingPathComponent("state.sqlite").path
        process.environment = environment
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var text = ""
        func collect(until marker: String) {
            for _ in 0..<60 {
                if text.contains(marker) { return }
                var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 100) > 0 {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = Darwin.read(master, &bytes, bytes.count)
                    if count > 0 { text += String(decoding: bytes.prefix(count), as: UTF8.self) }
                }
            }
        }
        collect(until: "[h] Hold")
        #expect(text.contains("[h] Hold"))
        if interrupt { kill(process.processIdentifier, SIGINT) }
        else { var eof: UInt8 = 4; _ = Darwin.write(master, &eof, 1) }
        collect(until: "--resume")
        #expect(text.contains("Progress saved."))
        #expect(text.contains("--resume"))
        #expect(!text.contains("squid") && !text.contains("kraken"))
        let stored = try #require(try f.state.inboxReviewSession())
        let session = try JSONDecoder().decode(InboxReviewSession.self, from: stored.snapshot)
        #expect(session.cursor == 0 && session.summary?.yes == 0)
    }
    #endif

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
    /// Seconds added to every time, for tests that run the real command and so see the real clock.
    let base: Double
    var cutoff: Date { Date().addingTimeInterval(-3600) }
    var window: SyncWindow { try! SyncWindow(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 200_000)) }
    var controller: InboxReviewSessionController { InboxReviewSessionController(state: state, lockURL: root.appendingPathComponent("review.lock"), now: { [base] in Date(timeIntervalSince1970: base) }) }
    var refresh: InboxReviewSessionController.Refresh { { try state.inboxContextSnapshot() } }
    var provider: InboxReviewSessionController.Provider { { _ in remote } }
    init(count: Int, overlapping: Bool = false, backend: String = "google", base: Double = 0) throws {
        self.count = count; self.overlapping = overlapping; self.base = base
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
                startsAt: Date(timeIntervalSince1970: base + (overlapping ? 10_000 : 10_000 + Double(index) * 20_000)),
                endsAt: Date(timeIntervalSince1970: base + (overlapping ? 11_000 : 11_000 + Double(index) * 20_000)),
                isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false, title: title ?? "Example \(index)", contentFingerprint: "example", providerUpdatedAt: nil, location: "Example room", notes: "Example notes", url: "https://example.com/meeting", organizer: EventParticipant(name: "Taylor Example", emailAddress: "taylor@example.com"),
                currentUserResponse: EventResponse(state: .needsResponse, evidence: .googleSelf, actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
        }
        try state.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar", windowStart: window.start, windowEnd: window.end, instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
    }
    func replace(_ key: String, start: Double? = nil, end: Double? = nil, response: EventResponseState? = nil, title: String? = nil) throws {
        var events = try state.inboxContextSnapshot().events.map(\.event)
        let index = try #require(events.firstIndex { $0.sourceKeyHash == key })
        let old = events[index]
        events[index] = StoredNormalizedInstance(sourceKeyHash: key, connectionID: "connection", calendarBindingID: "calendar",
            providerEventID: key, recurrenceID: nil, startsAt: start.map(Date.init(timeIntervalSince1970:)) ?? old.startsAt,
            endsAt: end.map(Date.init(timeIntervalSince1970:)) ?? old.endsAt, isAllDay: false, availability: "busy",
            isCancelled: false, isPrivate: false, title: title ?? old.title, contentFingerprint: "example", providerUpdatedAt: nil,
            currentUserResponse: EventResponse(state: response ?? old.currentUserResponse.state, evidence: .googleSelf,
                actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
        try state.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar", windowStart: window.start,
            windowEnd: window.end, instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
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
    enum Mode { case confirmed, failed, unknown, staleOnce, previewFailed, seriesOnly, differentScope }
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
        let returnedTarget = mode == .differentScope ? RSVPTarget(provider: target.provider, connectionID: target.connectionID,
            calendarBindingID: target.calendarBindingID, calendarID: target.calendarID, eventID: "series", seriesID: "series", originalStart: nil) : target
        return RSVPEventSnapshot(target: returnedTarget, event: event, version: "v1", capability: RSVPActionCapability(supportedScopes: mode == .seriesOnly ? [.series] : [.occurrence]), notification: .googleAllGuests, concurrency: .conditionalUpdate)
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
