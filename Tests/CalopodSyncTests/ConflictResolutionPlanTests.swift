import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

extension InboxConflictTests {
    func plan(_ events: [StoredNormalizedInstance], _ decisions: [(String, InboxConflictChoice)]) throws -> ConflictResolutionPreview {
        try ConflictResolutionPlanner.preview(
            decisions.map { ConflictDecision(sourceKeyHash: $0.0, choice: $0.1) },
            in: snapshot(events), window: window, freshnessCutoff: cutoff
        )
    }
}

@Suite("Combined conflict resolution preview")
struct ConflictResolutionPlanTests {
    private let base = InboxConflictTests()

    @Test("Declining one of two overlapping events resolves the pair")
    func declineResolves() throws {
        let events = [base.event("a", supported: true), base.event("b", supported: true)]
        let preview = try base.plan(events, [("a", .no), ("b", .hold)])
        #expect(preview.changes == [ConflictDecision(sourceKeyHash: "a", choice: .no)])
        #expect(preview.unchanged == ["b"])
        #expect(preview.resolved == [InboxConflictPair("a", "b")])
        #expect(preview.remaining.isEmpty)
        #expect(preview.created.isEmpty)
        #expect(preview.isComplete)
    }

    @Test("No change for every event leaves every conflict in place")
    func noChange() throws {
        let events = [base.event("a", supported: true), base.event("b", supported: true)]
        let preview = try base.plan(events, [("a", .hold), ("b", .hold)])
        #expect(preview.changes.isEmpty)
        #expect(preview.remaining == [InboxConflictPair("a", "b")])
        #expect(preview.resolved.isEmpty)
    }

    @Test("Several decisions are projected together, not one at a time")
    func combined() throws {
        let events = [base.event("a", supported: true), base.event("b", supported: true), base.event("c", supported: true)]
        let one = try base.plan(events, [("a", .no)])
        #expect(one.remaining == [InboxConflictPair("b", "c")])
        let two = try base.plan(events, [("a", .no), ("b", .no)])
        #expect(two.remaining.isEmpty)
        #expect(two.resolved.count == 3)
    }

    @Test("Accepting a declined event reports the conflict it would create")
    func createsConflict() throws {
        let events = [base.event("a", response: .declined, supported: true), base.event("b", supported: true)]
        let preview = try base.plan(events, [("a", .yes)])
        #expect(preview.created == [InboxConflictPair("a", "b")])
        #expect(preview.resolved.isEmpty)
    }

    @Test("A reply the provider can't send is rejected rather than dropped")
    func unavailableChoice() throws {
        let events = [base.event("a", supported: false), base.event("b", supported: true)]
        #expect(throws: ConflictResolutionError.choiceUnavailable("a")) {
            try base.plan(events, [("a", .no)])
        }
        #expect(try base.plan(events, [("a", .hold)]).changes.isEmpty)
    }

    @Test("Unknown and repeated events are rejected")
    func invalidDecisions() throws {
        let events = [base.event("a", supported: true), base.event("b", supported: true)]
        #expect(throws: ConflictResolutionError.unknownEvent("zzz")) { try base.plan(events, [("zzz", .hold)]) }
        #expect(throws: ConflictResolutionError.duplicateDecision("a")) {
            try base.plan(events, [("a", .no), ("a", .maybe)])
        }
    }
}
