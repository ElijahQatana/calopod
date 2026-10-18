import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Overlap sweep")
struct InboxOverlapSweepTests {
    private func item(_ key: String, _ start: Int, _ end: Int, allDay: Bool = false, availability: String = "busy",
                      response: EventResponseState = .accepted, confirmed: Bool = true) -> InboxContextEvent {
        InboxContextEvent(
            event: StoredNormalizedInstance(
                sourceKeyHash: key, connectionID: "c", calendarBindingID: "work", providerEventID: key, recurrenceID: nil,
                startsAt: Date(timeIntervalSince1970: Double(start) * 3600), endsAt: Date(timeIntervalSince1970: Double(end) * 3600),
                isAllDay: allDay, availability: availability, isCancelled: false, isPrivate: false,
                title: key, contentFingerprint: key, providerUpdatedAt: nil,
                currentUserResponse: EventResponse(state: response, evidence: .googleSelf,
                                                   actionCapability: RSVPActionCapability(supportedScopes: [.occurrence]))),
            isPresenceConfirmed: confirmed)
    }

    @Test("The sweep finds the same pairs, groups and attention conflicts as comparing every pair")
    func samePairs() throws {
        let events = [
            item("a", 10, 12), item("b", 12, 14),                  // back to back
            item("c", 9, 20), item("d", 13, 14), item("e", 15, 16), // nested in c
            item("f", 30, 32), item("g", 30, 32),                   // identical times
            item("h", 40, 64, allDay: true), item("i", 50, 51),     // all-day over a timed event
            item("j", 70, 72), item("k", 71, 73, confirmed: false), // unconfirmed copy
            item("l", 80, 82, availability: "free"), item("m", 80, 82, response: .declined), item("n", 80, 82),
        ]
        let source = InboxContextSource(
            bindingID: "work", connectionID: "c", provider: "google",
            coverage: InboxCoverage(startsAt: Date(timeIntervalSince1970: 0), endsAt: Date(timeIntervalSince1970: 100 * 3600),
                                    observedAt: Date()), healthStatus: "healthy")
        let snapshot = InboxContextSnapshot(sources: [source], events: events)
        let analysis = InboxConflictCalculator.analyze(snapshot, window: nil, freshnessCutoff: .distantPast)

        var expected: [InboxConflictPair: Bool] = [:]
        let blocking = events.filter { $0.event.currentUserResponse.state != .declined && $0.event.availability != "free" }
        for (index, x) in blocking.enumerated() {
            for y in blocking.dropFirst(index + 1) where x.event.startsAt < y.event.endsAt && y.event.startsAt < x.event.endsAt {
                expected[InboxConflictPair(x.event.sourceKeyHash, y.event.sourceKeyHash)] = x.isPresenceConfirmed && y.isPresenceConfirmed
            }
        }
        #expect(Dictionary(uniqueKeysWithValues: analysis.conflicts.map { ($0.pair, $0.isConfirmed) }) == expected)
        #expect(expected.count == 8 && expected[InboxConflictPair("a", "b")] == nil)

        let group = InboxConflictCalculator.group(containing: "d", conflicts: analysis.conflicts)
        #expect(group == ["a", "b", "c", "d", "e"])

        let rows = InboxAttentionQuery.evaluate(snapshot, filter: InboxAttentionFilter(conflictsOnly: true), freshnessCutoff: .distantPast).rows
        for row in rows {
            let key = row.item.event.sourceKeyHash
            #expect(Set(row.conflicts.map(\.pair)) == Set(expected.filter { $0.key.contains(key) && $0.value }.keys))
        }
    }
}
