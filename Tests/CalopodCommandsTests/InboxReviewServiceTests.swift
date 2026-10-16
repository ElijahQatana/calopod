#if os(macOS)
import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import Testing

@testable import CalopodCommands

@Suite("Mac inbox review")
struct InboxReviewServiceTests {
    @Test("Held and Maybe items stay out of the rest of the session, including after resume")
    func holdAndMaybeDoNotReturn() async throws {
        let f = try ReviewFixture(count: 4)
        var progress = try f.service.start(overlapsOnly: false, skipMaybe: false)
        #expect(progress.total == 4)

        var card = try #require(try await f.service.card(sessionID: progress.sessionID))
        #expect(card.position == 1 && card.entry.id == "key0")
        _ = await f.service.hold(card: card)
        card = try #require(try await f.service.card(sessionID: progress.sessionID))
        let (step, _) = await f.service.reply(.maybe, card: card)
        #expect(step == .recorded(.maybe))

        // Closing the sheet here and choosing Resume continues with the third event.
        progress = try await f.service.resume()
        let unfinished = try #require(try f.service.unfinished())
        #expect(unfinished.sessionID == progress.sessionID && unfinished.reviewed == 2)
        card = try #require(try await f.service.card(sessionID: progress.sessionID))
        #expect(card.entry.id == "key2" && card.position == 3)

        _ = await f.service.reply(.no, card: card)
        card = try #require(try await f.service.card(sessionID: progress.sessionID))
        let (last, done) = await f.service.reply(.yes, card: card)
        #expect(last == .recorded(.yes))
        #expect(try await f.service.card(sessionID: progress.sessionID) == nil)
        let totals = try #require(done).totals
        #expect(totals.held == 1 && totals.maybe == 1 && totals.no == 1 && totals.yes == 1 && totals.recorded == 3)
        #expect(await f.remote.writes == 3)
        #expect(try f.service.unfinished() == nil)
    }

    @Test("An unclear outcome is never sent again, and Resume only checks it")
    func unclearIsNotResent() async throws {
        let f = try ReviewFixture(count: 2)
        await f.remote.setMode(.unknown)
        let progress = try f.service.start(overlapsOnly: false, skipMaybe: false)
        let card = try #require(try await f.service.card(sessionID: progress.sessionID))
        let (step, after) = await f.service.reply(.yes, card: card)
        #expect(step == .unclear)
        #expect(after?.hasUnclear == true && after?.totals.unclear == 1 && after?.totals.recorded == 0)
        #expect(await f.remote.writes == 1)

        let resumed = try await f.service.resume()
        #expect(resumed.hasUnclear && !resumed.totals.queueReviewed)
        #expect(await f.remote.writes == 1)

        // The check can also find out the reply did go through.
        await f.remote.setMode(.confirmed)
        try await f.remote.apply(response: .accepted, key: "key0")
        let settled = try await f.service.resume()
        #expect(!settled.hasUnclear && settled.totals.yes == 1)
        #expect(await f.remote.writes == 1)
    }

    @Test("A changed event shows its new version and nothing is sent")
    func changedEventNeedsANewChoice() async throws {
        let f = try ReviewFixture(count: 1)
        let progress = try f.service.start(overlapsOnly: false, skipMaybe: false)
        let card = try #require(try await f.service.card(sessionID: progress.sessionID))
        try f.apply(title: "Moved to Friday")
        let (step, _) = await f.service.reply(.yes, card: card)
        #expect(step == .changed)
        #expect(await f.remote.writes == 0)

        let fresh = try #require(try await f.service.card(sessionID: progress.sessionID))
        #expect(fresh.entry.title == "Moved to Friday")
        let (again, _) = await f.service.reply(.yes, card: fresh)
        #expect(again == .recorded(.yes))
    }

    @Test("Only replies the calendar allows are offered, with their overlaps and who is told")
    func offeredReplies() async throws {
        let f = try ReviewFixture(count: 2, overlapping: true)
        let progress = try f.service.start(overlapsOnly: true, skipMaybe: false)
        let card = try #require(try await f.service.card(sessionID: progress.sessionID))
        #expect(card.replies == [.yes, .no, .maybe])
        #expect(card.preview(for: .yes)?.overlaps == ["Example 1"])
        #expect(card.preview(for: .no)?.overlaps == [])
        #expect(card.account == "Example / Calendar")
        #expect(card.organizer == "Taylor Example")
        #expect(card.notification?.contains("Taylor Example") == true)
        #expect(card.neighbors.map(\.id) == ["key1"])

        let readOnly = try ReviewFixture(count: 1, provider: "eventkit")
        let local = try readOnly.service.start(overlapsOnly: false, skipMaybe: false)
        let plain = try #require(try await readOnly.service.card(sessionID: local.sessionID))
        #expect(plain.replies.isEmpty && plain.notification == nil)
        #expect(plain.detail.replyNote.contains("Calendar app"))
        #expect(plain.isMacCalendar && !card.isMacCalendar)
    }

    @Test("A Mac calendar event can only be held, sends nothing and does not count as answered")
    func macCalendarEventIsSkippedNotResolved() async throws {
        let f = try ReviewFixture(count: 2, provider: "eventkit")
        let progress = try f.service.start(overlapsOnly: false, skipMaybe: false)
        var card = try #require(try await f.service.card(sessionID: progress.sessionID))
        let (denied, _) = await f.service.reply(.yes, card: card)
        #expect(denied != .recorded(.yes))
        _ = await f.service.hold(card: card)
        card = try #require(try await f.service.card(sessionID: progress.sessionID))
        let (_, done) = await f.service.hold(card: card)
        let totals = try #require(done).totals
        #expect(await f.remote.writes == 0)
        #expect(totals.held == 2 && totals.recorded == 0 && totals.queueReviewed && !totals.inboxResolved)
        #expect(totals.remainingInbox == 2)
    }

    @Test("The summary counts overlaps resolved separately from replies recorded")
    func summarySeparatesReviewedFromResolved() async throws {
        let f = try ReviewFixture(count: 2, overlapping: true)
        let progress = try f.service.start(overlapsOnly: true, skipMaybe: false)
        var card = try #require(try await f.service.card(sessionID: progress.sessionID))
        _ = await f.service.reply(.no, card: card)
        card = try #require(try await f.service.card(sessionID: progress.sessionID))
        let (_, done) = await f.service.hold(card: card)
        let totals = try #require(done).totals
        #expect(totals.queueReviewed && totals.no == 1 && totals.held == 1)
        #expect(totals.overlapsResolved == 1 && totals.overlapsCreated == 0 && totals.overlapsRemaining == 0)
    }
}

private struct ReviewFixture {
    let state = LocalStateRepository(database: try! CalopodDatabase.inMemory())
    let remote: ReviewRemote
    let count: Int
    let overlapping: Bool
    let window = try! SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 200_000))
    let lock = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).lock")

    init(count: Int, overlapping: Bool = false, provider: String = "google") throws {
        self.count = count
        self.overlapping = overlapping
        remote = ReviewRemote(state: state, window: window)
        try state.saveConnection(StoredConnection(id: "c", configurationID: "d", provider: provider, displayLabel: "Example", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "c", bindings: [
            StoredCalendarBinding(id: "cal", connectionID: "c", providerCalendarID: "primary", displayLabel: "Calendar",
                                  isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser),
        ])
        try apply()
    }

    var service: InboxReviewService {
        let state = state, remote = remote, lock = lock
        return InboxReviewService(
            makeRepository: { state }, makeLockURL: { lock },
            makeRefresh: { state in { try state.inboxContextSnapshot() } }, provider: { _ in remote })
    }

    func apply(title: String? = nil) throws {
        let events = (0..<count).map { index in
            let start = overlapping ? 10_000 : 10_000 + Double(index) * 20_000
            return StoredNormalizedInstance(
                sourceKeyHash: "key\(index)", connectionID: "c", calendarBindingID: "cal", providerEventID: "key\(index)",
                recurrenceID: nil, startsAt: Date(timeIntervalSince1970: start), endsAt: Date(timeIntervalSince1970: start + 1000),
                isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false, title: title ?? "Example \(index)",
                contentFingerprint: title ?? "example", providerUpdatedAt: nil,
                organizer: EventParticipant(name: "Taylor Example", emailAddress: "taylor@example.com"),
                currentUserResponse: EventResponse(state: .needsResponse, evidence: .googleSelf,
                                                   actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
        }
        try state.applyEventRefresh(connectionID: "c", calendarBindingID: "cal", windowStart: window.start, windowEnd: window.end,
                                    instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
    }
}

private actor ReviewRemote: RSVPActionProvider {
    enum Mode { case confirmed, unknown }
    let state: LocalStateRepository
    let window: SyncWindow
    var writes = 0
    var mode = Mode.confirmed
    init(state: LocalStateRepository, window: SyncWindow) { self.state = state; self.window = window }
    func setMode(_ mode: Mode) { self.mode = mode }

    func rsvpSnapshot(target: RSVPTarget) async throws -> RSVPEventSnapshot {
        let local = try #require(try state.inboxContextSnapshot().events.first { $0.event.sourceKeyHash == target.eventID }?.event)
        let event = ProviderEvent(
            provider: "google", connectionID: target.connectionID, calendarID: target.calendarID, eventID: target.eventID,
            seriesID: nil, originalStart: nil, start: local.startsAt, end: local.endsAt, isAllDay: false, availability: .busy,
            isCancelled: false, isPrivate: false, title: local.title, updatedAt: nil, location: local.location, notes: local.notes,
            url: local.url, organizer: local.organizer, responseMetadata: local.currentUserResponse)
        return RSVPEventSnapshot(target: target, event: event, version: "v1",
                                 capability: RSVPActionCapability(supportedScopes: [.occurrence]),
                                 notification: .googleAllGuests, concurrency: .conditionalUpdate)
    }

    func submitRSVP(_ intent: RSVPActionIntent) async throws {
        writes += 1
        if mode == .unknown { throw RSVPActionError.uncertain }
        try apply(response: intent.decision.responseState, key: intent.target.eventID)
    }

    func reconcileRSVP(_ record: RSVPActionRecord) async throws -> RSVPActionOutcome {
        try await RSVPReadback.outcome(record, snapshot: rsvpSnapshot(target: record.intent.target))
    }

    func apply(response: EventResponseState, key: String) throws {
        var events = try state.inboxContextSnapshot().events.map(\.event)
        let index = try #require(events.firstIndex { $0.sourceKeyHash == key })
        let old = events[index]
        events[index] = StoredNormalizedInstance(
            sourceKeyHash: old.sourceKeyHash, connectionID: old.connectionID, calendarBindingID: old.calendarBindingID,
            providerEventID: old.providerEventID, recurrenceID: nil, startsAt: old.startsAt, endsAt: old.endsAt, isAllDay: false,
            availability: old.availability, isCancelled: false, isPrivate: false, title: old.title,
            contentFingerprint: old.contentFingerprint, providerUpdatedAt: nil, organizer: old.organizer,
            currentUserResponse: EventResponse(state: response, evidence: .googleSelf,
                                               actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
        try state.applyEventRefresh(connectionID: "c", calendarBindingID: "cal", windowStart: window.start, windowEnd: window.end,
                                    instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
    }
}
#endif
