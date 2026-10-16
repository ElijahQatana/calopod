#if os(macOS)
import CalopodDomain
import CalopodProviders
import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands

@Suite("Mac inbox service")
struct InboxScreenServiceTests {
    @Test("Filter counts match the reasons calopod inbox reports")
    func countsMatchCommand() throws {
        let f = try InboxFixture()
        let board = try f.service.board()
        let payload = try InboxCLI.list(repository: f.state, options: InboxOptions.parse([]), range: nil, activity: false)
        let reasons = (payload.items ?? []).flatMap { $0.inbox?.reasons ?? [] }

        let expected: [(InboxFilter, String?)] = [
            (.all, nil), (.needsRSVP, "needs-response"), (.maybe, "maybe"),
            (.changed, "changed-after-response"), (.conflicts, "conflict"),
        ]
        for (filter, reason) in expected {
            #expect(board.count(filter) == (reason.map { name in reasons.filter { $0 == name }.count } ?? payload.count))
        }
        #expect(board.count(.all) == 6)
        #expect(Set(board.entries.map(\.id)) == ["needs", "maybe", "chg", "mb", "a", "b"])
    }

    @Test("Copies Calopod made are left out")
    func copiesExcluded() throws {
        let f = try InboxFixture()
        #expect(!(try f.service.board().entries.map(\.id).contains("copy")))
    }

    @Test("Acknowledge clears only the change, never a Maybe")
    func acknowledgeKeepsMaybe() throws {
        let f = try InboxFixture()
        let before = try f.service.board()
        #expect(before.count(.changed) == 2)

        try f.service.acknowledge(revisionID: try #require(before.entries.first { $0.id == "mb" }).revisionID)

        let after = try f.service.board()
        #expect(after.count(.changed) == 1)
        #expect(after.entries(for: .maybe).map(\.id).sorted() == ["maybe", "mb"])
        #expect(after.count(.all) == 6)
    }

    @Test("Replies come only from the calendar's own choices")
    func detailChoices() throws {
        let f = try InboxFixture()
        #expect(try f.service.detail(for: "needs").replies == [.yes, .no, .maybe])
        let readOnly = try InboxFixture(provider: "eventkit")
        let detail = try readOnly.service.detail(for: "needs")
        #expect(detail.replies.isEmpty)
        #expect(detail.replyNote.contains("Calendar app"))
    }

    @Test("A stale calendar is reported and the last check is known")
    func staleBanner() throws {
        let f = try InboxFixture(now: Date().addingTimeInterval(7200))
        let board = try f.service.board()
        #expect(!board.isComplete)
        #expect(board.incompleteCalendars == ["Calendar"])
        #expect(board.lastChecked != nil)
    }

    @Test("The context strip rings overlaps and uses 90 minutes either side")
    func contextStrip() throws {
        let f = try InboxFixture()
        let detail = try f.service.detail(for: "a")
        #expect(detail.windowEnd.timeIntervalSince(detail.windowStart) == 180 * 60)
        #expect(detail.context.filter(\.overlapsFocused).map(\.id) == ["b"])
        #expect(detail.context.filter(\.isFocused).map(\.id) == ["a"])
    }
}

private struct InboxFixture {
    let state = LocalStateRepository(database: try! CalopodDatabase.inMemory())
    let now: Date

    init(provider: String = "google", now: Date = Date()) throws {
        self.now = now
        try state.saveConnection(StoredConnection(id: "c", configurationID: "d", provider: provider, displayLabel: "Example", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "c", bindings: [
            StoredCalendarBinding(id: "cal", connectionID: "c", providerCalendarID: "p", displayLabel: "Calendar",
                                  isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser),
        ])
        let accepted: [(String, EventResponseState, Double)] = [("chg", .accepted, 100_000), ("mb", .tentative, 150_000)]
        let base = [event("needs", .needsResponse, 1000), event("maybe", .tentative, 50_000), event("a", .accepted, 200_000),
                    event("b", .accepted, 200_500), event("copy", .needsResponse, 300_000)]
            + accepted.map { event($0.0, $0.1, $0.2) }
        try refresh(base)
        try refresh(base.map { $0.sourceKeyHash == "chg" || $0.sourceKeyHash == "mb" ? event($0.sourceKeyHash, $0.currentUserResponse.state, $0.startsAt.timeIntervalSince1970, notes: "Moved to room 2") : $0 })
        try state.saveArm(StoredArm(id: "arm", configurationID: "d", sourceBindingIDs: ["cal"], targetBindingID: "cal", ruleMode: .busy))
        try state.saveMirrorMapping(StoredMirrorMapping(mirrorKey: "m", armID: "arm", sourceKeyHash: "a", providerEventID: "copy",
                                                        providerVersion: nil, desiredFingerprint: "x", ownershipKeyID: "k", updatedAt: Date()))
    }

    var service: InboxScreenService {
        let repository = state, now = now
        return InboxScreenService(
            makeRepository: { repository },
            makeLockURL: { FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString).lock") },
            makeRefresh: { state in { try state.inboxContextSnapshot() } },
            provider: { _ in throw RSVPActionError.unavailable(.unsupported) }, now: { now })
    }

    func event(_ key: String, _ response: EventResponseState, _ start: Double, notes: String? = nil) -> StoredNormalizedInstance {
        StoredNormalizedInstance(
            sourceKeyHash: key, connectionID: "c", calendarBindingID: "cal", providerEventID: key, recurrenceID: nil,
            startsAt: Date(timeIntervalSince1970: start), endsAt: Date(timeIntervalSince1970: start + 1800), isAllDay: false,
            availability: "busy", isCancelled: false, isPrivate: false, title: "Event \(key)", contentFingerprint: "x",
            providerUpdatedAt: nil, notes: notes,
            currentUserResponse: EventResponse(state: response, evidence: .googleSelf,
                                               actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
    }

    func refresh(_ events: [StoredNormalizedInstance]) throws {
        try state.applyEventRefresh(
            connectionID: "c", calendarBindingID: "cal", windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 400_000), instances: events, cancelledSourceKeyHashes: [],
            isFullRefresh: true, cursorUpdates: [], now: Date())
    }
}
#endif
