import Foundation
import Testing

@testable import CalopodCommands

@Suite("Next event selection")
struct NextUpTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Minutes after `start`.
    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func entry(_ id: String, _ from: Double, _ to: Double) -> NextUpEntry {
        NextUpEntry(id: id, startsAt: at(from), endsAt: at(to))
    }

    private func pick(_ events: [NextUpEntry], at minutes: Double) -> (String?, String?, NextUpSelection.Role?, NextUpSelection.Role?) {
        let chosen = NextUpSelection.select(events, now: at(minutes))
        return (chosen.primary?.event.id, chosen.secondary?.event.id, chosen.primary?.role, chosen.secondary?.role)
    }

    @Test("In the first ten minutes the running meeting stays primary and the next is secondary")
    func beforeTenMinutes() {
        let events = [entry("run", 0, 60), entry("next", 30, 60), entry("later", 90, 120)]
        for minute in [0.0, 5, 9.9] {
            let (primary, secondary, roles, secondRole) = pick(events, at: minute)
            #expect(primary == "run" && secondary == "next")
            #expect(roles == .current && secondRole == .upcoming)
        }
    }

    @Test("From ten minutes in, the next event is primary and the running one is a small line")
    func afterTenMinutes() {
        let events = [entry("run", 0, 60), entry("next", 30, 60)]
        let (primary, secondary, role, secondRole) = pick(events, at: 10)
        #expect(primary == "next" && secondary == "run")
        #expect(role == .upcoming && secondRole == .inProgress)
    }

    @Test("With nothing upcoming the running meeting stays until it ends")
    func noneUpcoming() {
        let events = [entry("run", 0, 60)]
        #expect(pick(events, at: 45).0 == "run" && pick(events, at: 45).1 == nil)
        #expect(pick(events, at: 60).0 == nil)
    }

    @Test("Of two running events the one that started last is current, and the other is named")
    func overlapping() {
        let events = [entry("a", 0, 60), entry("b", 5, 90)]
        let chosen = NextUpSelection.select(events, now: at(8))
        #expect(chosen.primary?.event.id == "b")
        #expect(chosen.alsoRunning.map(\.id) == ["a"])
    }

    @Test("An event starting in two minutes does not take over before the running one is ten minutes in")
    func startingSoon() {
        let events = [entry("run", 0, 60), entry("soon", 14, 40)]
        #expect(pick(events, at: 12).0 == "soon" && pick(events, at: 12).2 == .upcoming)
        let early = [entry("run", 0, 60), entry("soon", 7, 40)]
        #expect(pick(early, at: 5).0 == "run" && pick(early, at: 5).1 == "soon")
    }

    @Test("A 15:00 event is next at 14:40 while a 14:30 meeting runs")
    func shownBelowThenPrimary() {
        let events = [entry("meeting", 0, 60), entry("three", 30, 45), entry("half", 60, 90)]
        #expect(pick(events, at: 9).0 == "meeting" && pick(events, at: 9).1 == "three")
        #expect(pick(events, at: 10).0 == "three" && pick(events, at: 10).1 == "meeting")
    }

    @Test("Ended events disappear and nothing is chosen when nothing is left")
    func ended() {
        #expect(pick([entry("old", -60, -1)], at: 0) == (nil, nil, nil, nil))
        #expect(pick([], at: 0).0 == nil)
    }

    @Test("Across midnight a running event carries on and one just after midnight is upcoming")
    func midnight() {
        // The test start is taken as 23:30, so 30 minutes is midnight; the early event starts at 00:05.
        let events = [entry("late", 0, 45), entry("early", 35, 60)]
        #expect(pick(events, at: 5).0 == "late" && pick(events, at: 5).1 == "early")
        #expect(pick(events, at: 40).0 == "early")
    }

    @Test("The next change is the nearest start, ten minute mark or end after now")
    func nextChange() {
        let events = [entry("a", 0, 60), entry("b", 30, 45)]
        #expect(NextUpSelection.nextChange(events, after: at(1)) == at(10))
        #expect(NextUpSelection.nextChange(events, after: at(10)) == at(30))
        #expect(NextUpSelection.nextChange(events, after: at(61)) == nil)
    }
}
