#if os(macOS)
import CalopodDomain
import CalopodSnapshot
import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func fixture() throws -> LocalStateRepository {
    let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
    try state.saveConnection(StoredConnection(
        id: "c", configurationID: "config", provider: "google", displayLabel: "Example", isEnabled: true))
    try state.replaceCalendarBindings(connectionID: "c", bindings: [
        StoredCalendarBinding(
            id: "cal", connectionID: "c", providerCalendarID: "cal", displayLabel: "Work",
            isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser),
    ])
    func event(_ key: String, hour: Double, isPrivate: Bool) -> StoredNormalizedInstance {
        StoredNormalizedInstance(
            sourceKeyHash: key, connectionID: "c", calendarBindingID: "cal", providerEventID: key, recurrenceID: nil,
            startsAt: now.addingTimeInterval(hour * 3600), endsAt: now.addingTimeInterval((hour + 1) * 3600),
            isAllDay: false, availability: "busy", isCancelled: false, isPrivate: isPrivate, title: "Title \(key)",
            contentFingerprint: key, providerUpdatedAt: nil, location: "Room 4", notes: String(repeating: "n", count: 5_000),
            attendees: [EventParticipant(emailAddress: "a@example.com", status: "accepted"), EventParticipant(status: "declined")],
            currentUserResponse: EventResponse(
                state: .needsResponse, evidence: .googleSelf,
                actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
    }
    try state.applyEventRefresh(
        connectionID: "c", calendarBindingID: "cal", windowStart: now.addingTimeInterval(-86_400),
        windowEnd: now.addingTimeInterval(7 * 86_400),
        instances: [event("a", hour: 2, isPrivate: false), event("b", hour: 2.5, isPrivate: true)],
        cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
    return state
}

private func finishSync(_ state: LocalStateRepository, id: String) throws {
    try state.beginSyncRun(mode: "apply", trigger: "automatic", id: id, now: now)
    try state.finishSyncRun(id: id, status: "succeeded", now: now)
}

private func service(_ state: LocalStateRepository, at date: Date = now) -> IPhoneFeedService {
    IPhoneFeedService(makeRepository: { state }, now: { date })
}

@Suite("iPhone feed")
struct IPhoneFeedTests {
    @Test("The records carry what the phone shows, and a private event keeps only its time")
    func buildsRecords() throws {
        let state = try fixture()
        try finishSync(state, id: "run1")
        let records = try IPhoneFeedBuilder.records(repository: state, now: now, calendar: Calendar(identifier: .gregorian))
        let kinds = Dictionary(grouping: records, by: \.kind).mapValues(\.count)
        #expect(kinds[.inboxItem] == 2 && kinds[.availabilityDay] == IPhoneFeedBuilder.availabilityDays)
        #expect(kinds[.calendars] == 1 && kinds[.syncStatus] == 1)

        func item(_ key: String) throws -> InboxItem {
            let payload = try #require(records.first { $0.recordName == key })
            return try SnapshotCoding.decode(InboxItem.self, from: payload.bytes).record
        }
        let open = try item("a"), hidden = try item("b")
        #expect(open.title == "Title a" && open.location == "Room 4" && open.notes?.count == IPhoneFeedBuilder.notesLimit)
        #expect(open.reasons.contains(.needsRSVP) && open.reasons.contains(.conflict))
        #expect(open.attendees == AttendeeSummary(total: 2, accepted: 1, declined: 1))
        #expect(open.conflicts.first?.title == nil)
        #expect(hidden.title == nil && hidden.location == nil && hidden.notes == nil && hidden.organizerName == nil)
        #expect(open.conflicts.map(\.startsAt) == [hidden.startsAt])

        let list = try #require(records.first { $0.kind == .calendars })
        #expect(try SnapshotCoding.decode(CalendarList.self, from: list.bytes).record.calendars
            == [CalendarEntry(id: "cal", name: "Work", colorIndex: 11)])
        let status = try #require(records.first { $0.kind == .syncStatus })
        #expect(try SnapshotCoding.decode(SyncStatus.self, from: status.bytes).record.lastSyncAt == now)
    }

    @Test("Nothing is sent until it is turned on, then once per sync")
    func publishesAfterEachSync() async throws {
        let state = try fixture()
        let feed = service(state), remote = InMemorySnapshotPublisher()
        try finishSync(state, id: "run1")
        #expect(await feed.run(publisher: remote) == .idle)
        #expect(await remote.replaceCount == 0)

        try feed.setEnabled(true)
        guard case .published(let count) = await feed.run(publisher: remote) else { Issue.record("not published"); return }
        let stored = await remote.records.count
        #expect(count == 2 + IPhoneFeedBuilder.availabilityDays + 2 && stored == count)
        #expect(await feed.run(publisher: remote) == .idle)

        try finishSync(state, id: "run2")
        guard case .published = await feed.run(publisher: remote) else { Issue.record("not published"); return }
        #expect(await remote.replaceCount == 2)
        #expect(try feed.state().publishedRunID == "run2")
    }

    @Test("A failed upload is recorded, retried later, and never thrown")
    func failureIsShownAndRetried() async throws {
        let state = try fixture()
        try finishSync(state, id: "run1")
        let remote = InMemorySnapshotPublisher()
        await remote.setFailing(true)
        try service(state).setEnabled(true)
        guard case .failed = await service(state).run(publisher: remote) else { Issue.record("did not fail"); return }
        let failed = try service(state).state()
        #expect(failed.failure != nil && failed.failedAt == now && failed.publishedAt == nil)

        await remote.setFailing(false)
        #expect(await service(state, at: now.addingTimeInterval(60)).run(publisher: remote) == .idle)
        let later = now.addingTimeInterval(IPhoneFeedService.retryDelay + 1)
        guard case .published = await service(state, at: later).run(publisher: remote) else { Issue.record("not retried"); return }
        #expect(try service(state).state().failure == nil)
    }

    @Test("Turning it off deletes the remote copy once, even if the first try fails")
    func offDeletesRemote() async throws {
        let state = try fixture()
        try finishSync(state, id: "run1")
        let remote = InMemorySnapshotPublisher()
        try service(state).setEnabled(true)
        _ = await service(state).run(publisher: remote)

        try service(state).setEnabled(false)
        #expect(try service(state).state().removePending)
        await remote.setFailing(true)
        guard case .failed = await service(state).run(publisher: remote) else { Issue.record("did not fail"); return }
        #expect(try service(state).state().removePending)

        await remote.setFailing(false)
        let later = now.addingTimeInterval(IPhoneFeedService.retryDelay + 1)
        #expect(await service(state, at: later).run(publisher: remote) == .removed)
        #expect(await remote.records.isEmpty)
        #expect(try service(state).state() == StoredIPhoneFeed())
        #expect(await service(state, at: later).run(publisher: remote) == .idle)
    }

    @Test("The command line says why the feed is not available")
    func availabilityWording() {
        let app = URL(fileURLWithPath: "/Applications/Calopod.app")
        let signed = IPhoneFeedAvailability.check(app: app, exists: { $0.hasSuffix("embedded.provisionprofile") })
        #expect(signed == .available)
        #expect(IPhoneFeedAvailability.check(app: app, exists: { _ in false }) == .notSigned)
        #expect(IPhoneFeedAvailability.check(app: nil, exists: { _ in true }) == .noApp)
        #expect(IPhoneFeedAvailability.noApp.describe(StoredIPhoneFeed()) == "iPhone feed: not available (no app)")
        #expect(signed.describe(StoredIPhoneFeed()) == "iPhone feed: off")
        let item = iPhoneFeedDoctorItem(availability: .noApp, feed: { nil })
        #expect(item.item.kind == "skipped" && item.item.reason == "no-app" && item.warning == nil)
    }
}
#endif
