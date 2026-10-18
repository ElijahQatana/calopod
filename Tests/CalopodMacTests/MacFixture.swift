import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import XCTest

@testable import CalopodCommands

/// A local copy with a few Needs RSVP events and a fake calendar that records what is sent.
struct MacFixture {
    let state = LocalStateRepository(database: try! CalopodDatabase.inMemory())
    let remote: FakeRemote
    let overlapping: Bool
    let window = try! SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 200_000))
    let lock = FileManager.default.temporaryDirectory.appendingPathComponent("mac-\(UUID().uuidString).lock")
    let now = Date(timeIntervalSince1970: 5_000)

    init(count: Int, overlapping: Bool = false, provider: String = "google") throws {
        self.overlapping = overlapping
        remote = FakeRemote(state: state, window: window)
        try state.saveConnection(StoredConnection(id: "c", configurationID: "d", provider: provider, displayLabel: "Example", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "c", bindings: [
            StoredCalendarBinding(id: "cal", connectionID: "c", providerCalendarID: "primary", displayLabel: "Calendar",
                                  isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser),
        ])
        try apply(keys: (0..<count).map { "key\($0)" })
    }

    var review: InboxReviewService {
        let state = state, remote = remote, lock = lock, now = now
        return InboxReviewService(
            makeRepository: { state }, makeLockURL: { lock },
            makeRefresh: { state in { try state.inboxContextSnapshot() } }, provider: { _ in remote }, now: { now })
    }

    var inbox: InboxScreenService {
        let state = state, remote = remote, lock = lock, now = now
        return InboxScreenService(
            makeRepository: { state }, makeLockURL: { lock },
            makeRefresh: { state in { try state.inboxContextSnapshot() } }, provider: { _ in remote }, now: { now })
    }

    /// Replaces what the calendar holds. A new title or response makes a new revision.
    func apply(keys: [String], title: String? = nil, response: EventResponseState = .needsResponse) throws {
        let events = keys.enumerated().map { index, key in
            let start = overlapping ? 10_000 : 10_000 + Double(index) * 20_000
            return event(key, start: start, title: title ?? "Example \(key)", response: response)
        }
        try state.applyEventRefresh(connectionID: "c", calendarBindingID: "cal", windowStart: window.start, windowEnd: window.end,
                                    instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
    }
}

func event(_ key: String, start: Double, title: String, response: EventResponseState) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: key, connectionID: "c", calendarBindingID: "cal", providerEventID: key,
        recurrenceID: nil, startsAt: Date(timeIntervalSince1970: start), endsAt: Date(timeIntervalSince1970: start + 1000),
        isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false, title: title,
        contentFingerprint: title, providerUpdatedAt: nil,
        organizer: EventParticipant(name: "Taylor Example", emailAddress: "taylor@example.com"),
        currentUserResponse: EventResponse(state: response, evidence: .googleSelf,
                                           actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
}

private struct NoSuchEvent: Error {}

actor FakeRemote: RSVPActionProvider {
    enum Mode { case confirmed, unknown }
    let state: LocalStateRepository
    let window: SyncWindow
    private(set) var writes = 0
    private var mode = Mode.confirmed
    init(state: LocalStateRepository, window: SyncWindow) { self.state = state; self.window = window }
    func setMode(_ mode: Mode) { self.mode = mode }

    func rsvpSnapshot(target: RSVPTarget) async throws -> RSVPEventSnapshot {
        guard let local = try state.inboxContextSnapshot().events.first(where: { $0.event.sourceKeyHash == target.eventID })?.event
        else { throw NoSuchEvent() }
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
        guard let index = events.firstIndex(where: { $0.sourceKeyHash == key }) else { throw NoSuchEvent() }
        let old = events[index]
        events[index] = event(key, start: old.startsAt.timeIntervalSince1970, title: old.title ?? "", response: response)
        try state.applyEventRefresh(connectionID: "c", calendarBindingID: "cal", windowStart: window.start, windowEnd: window.end,
                                    instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
    }
}
