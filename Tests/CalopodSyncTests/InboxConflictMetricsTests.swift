import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Inbox conflict decision metrics")
struct InboxConflictMetricsTests {
    let fixture = InboxConflictTests()

    @Test("Confirmed decisions count new pairs once; later resolution keeps created distinct from remaining")
    func confirmedAndExternal() throws {
        let before = fixture.snapshot([fixture.event("a", response: .declined), fixture.event("b"), fixture.event("c", start: 20_000, end: 21_000)])
        let after = fixture.snapshot([fixture.event("a"), fixture.event("b"), fixture.event("c", start: 11_000, end: 13_000)])
        var metrics = InboxConflictMetrics(starting: before, window: fixture.window, freshnessCutoff: fixture.cutoff)
        try metrics.recordConfirmedDecision(sourceKeyHash: "a", response: .accepted, before: before, after: after, freshnessCutoff: fixture.cutoff)
        #expect(metrics.createdPairs == [InboxConflictPair("a", "b")])
        #expect(metrics.externalPairs == [InboxConflictPair("a", "c"), InboxConflictPair("b", "c")])
        #expect(metrics.remainingPairs.count == 3)
        #expect(metrics.isComplete)
        try metrics.recordConfirmedDecision(sourceKeyHash: "a", response: .accepted, before: before, after: after, freshnessCutoff: fixture.cutoff)
        #expect(metrics.createdPairs.count == 1)
        let declined = fixture.snapshot([fixture.event("a", response: .declined), fixture.event("b"), fixture.event("c", start: 11_000, end: 13_000)])
        try metrics.recordConfirmedDecision(sourceKeyHash: "a", response: .declined, before: after, after: declined, freshnessCutoff: fixture.cutoff)
        #expect(metrics.createdPairs.count == 1)
        #expect(metrics.remainingPairs == [InboxConflictPair("b", "c")])
        let reopened = try JSONDecoder().decode(InboxConflictMetrics.self, from: JSONEncoder().encode(metrics))
        #expect(reopened == metrics)
    }

    @Test("Existing starting conflicts, Hold and external observations cannot inflate created")
    func startingAndHold() throws {
        let starting = fixture.snapshot([fixture.event("a"), fixture.event("b")])
        var metrics = InboxConflictMetrics(starting: starting, window: fixture.window, freshnessCutoff: fixture.cutoff)
        let declined = fixture.snapshot([fixture.event("a", response: .declined), fixture.event("b")])
        try metrics.recordConfirmedDecision(sourceKeyHash: "a", response: .declined, before: starting, after: declined, freshnessCutoff: fixture.cutoff)
        try metrics.recordConfirmedDecision(sourceKeyHash: "a", response: .accepted, before: declined, after: starting, freshnessCutoff: fixture.cutoff)
        #expect(metrics.createdPairs.isEmpty)
        #expect(throws: InboxConflictMetricsError.invalidConfirmedResponse) {
            try metrics.recordConfirmedDecision(sourceKeyHash: "a", response: .needsResponse, before: starting, after: starting, freshnessCutoff: fixture.cutoff)
        }
        let external = fixture.snapshot([fixture.event("a"), fixture.event("b"), fixture.event("c")])
        metrics.observeExternalChanges(before: starting, after: external, freshnessCutoff: fixture.cutoff)
        #expect(metrics.createdPairs.isEmpty)
        #expect(metrics.externalPairs == [InboxConflictPair("a", "c"), InboxConflictPair("b", "c")])
        #expect(metrics.remainingPairs.count == 3)
    }

    @Test("Unconfirmed outcomes are rejected and incomplete evidence stays uncertain")
    func incomplete() throws {
        let before = fixture.snapshot([fixture.event("a", response: .declined), fixture.event("b")])
        let after = fixture.snapshot([fixture.event("a"), fixture.event("b")])
        var metrics = InboxConflictMetrics(starting: before, window: fixture.window, freshnessCutoff: fixture.cutoff)
        #expect(throws: InboxConflictMetricsError.responseNotObserved) {
            try metrics.recordConfirmedDecision(sourceKeyHash: "a", response: .accepted, before: before, after: before, freshnessCutoff: fixture.cutoff)
        }
        #expect(metrics.createdPairs.isEmpty)
        let incomplete = InboxContextSnapshot(sources: [fixture.source("calendar", status: "stale"), fixture.source("other")], events: after.events)
        try metrics.recordConfirmedDecision(sourceKeyHash: "a", response: .accepted, before: before, after: incomplete, freshnessCutoff: fixture.cutoff)
        #expect(!metrics.isComplete)
        #expect(!metrics.attributionIsComplete)
        #expect(metrics.createdPairs.isEmpty)
        #expect(metrics.uncertainPairs == [InboxConflictPair("a", "b")])
        #expect(metrics.remainingPairs.count == 1)
        var missingBaseline = InboxConflictMetrics(starting: incomplete, window: fixture.window, freshnessCutoff: fixture.cutoff)
        missingBaseline.observeExternalChanges(before: incomplete, after: before, freshnessCutoff: fixture.cutoff)
        try missingBaseline.recordConfirmedDecision(sourceKeyHash: "a", response: .accepted, before: before, after: after, freshnessCutoff: fixture.cutoff)
        #expect(missingBaseline.createdPairs.isEmpty)
        #expect(!missingBaseline.attributionIsComplete)
    }

    @Test("Concurrent partner or focus moves cannot be attributed to the review response")
    func concurrentMoves() throws {
        let before = fixture.snapshot([fixture.event("a", response: .declined), fixture.event("b")])
        for after in [fixture.snapshot([fixture.event("a"), fixture.event("b", end: 13_000)]),
                      fixture.snapshot([fixture.event("a", end: 13_000), fixture.event("b")])] {
            var metrics = InboxConflictMetrics(starting: before, window: fixture.window, freshnessCutoff: fixture.cutoff)
            try metrics.recordConfirmedDecision(sourceKeyHash: "a", response: .accepted, before: before, after: after, freshnessCutoff: fixture.cutoff)
            #expect(metrics.createdPairs.isEmpty)
            #expect(metrics.uncertainPairs == [InboxConflictPair("a", "b")])
            #expect(!metrics.attributionIsComplete)
        }
    }

    @Test("Confirmed decline can disappear from the active view without a second action")
    func disappearedDecline() throws {
        let before = fixture.snapshot([fixture.event("a"), fixture.event("b")])
        let after = fixture.snapshot([fixture.event("b")])
        var metrics = InboxConflictMetrics(starting: before, window: fixture.window, freshnessCutoff: fixture.cutoff)
        try metrics.recordConfirmedDecision(sourceKeyHash: "a", response: .declined, before: before, after: after, freshnessCutoff: fixture.cutoff)
        #expect(metrics.remainingPairs.isEmpty)
        #expect(metrics.createdPairs.isEmpty)
        #expect(metrics.attributionIsComplete)
    }
}
