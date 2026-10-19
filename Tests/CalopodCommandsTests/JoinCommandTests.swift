import CalopodDomain
import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands

#if os(macOS)
@Suite("calopod join")
struct JoinCommandTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ key: String, hours: Double, length: Double = 1, url: String? = nil, notes: String? = nil,
        allDay: Bool = false, cancelled: Bool = false
    ) -> StoredNormalizedInstance {
        StoredNormalizedInstance(
            sourceKeyHash: key, connectionID: "c", calendarBindingID: "cal", providerEventID: key, recurrenceID: nil,
            startsAt: now.addingTimeInterval(hours * 3600), endsAt: now.addingTimeInterval((hours + length) * 3600),
            isAllDay: allDay, availability: "busy", isCancelled: cancelled, isPrivate: false, title: "Event \(key)",
            contentFingerprint: key, providerUpdatedAt: nil, notes: notes, url: url)
    }

    private struct Recorder: MeetingJoining {
        let result: MeetingJoinResult
        func join(_ link: MeetingLink) async -> MeetingJoinResult { result }
    }

    private func key(_ choice: JoinChoice) -> String? {
        if case let .event(event, _) = choice { event.sourceKeyHash } else { nil }
    }

    @Test("Without an id the next event with a link is chosen")
    func nextWithLink() {
        let events = [
            event("past", hours: -3, url: "https://zoom.us/j/111111111"),
            event("plain", hours: 0.5),
            event("later", hours: 3, notes: "Join <https://meet.google.com/abc-defg-hij>."),
            event("soonest", hours: 1, url: "https://zoom.us/j/222222222"),
            event("far", hours: 13, url: "https://zoom.us/j/333333333"),
        ]
        #expect(key(JoinSelector.choose(id: nil, from: events, now: now)) == "soonest")
    }

    @Test("A running event counts, and all-day and cancelled events are skipped")
    func running() {
        let events = [
            event("allday", hours: 0, length: 24, url: "https://zoom.us/j/111111111", allDay: true),
            event("cancelled", hours: 0, url: "https://zoom.us/j/222222222", cancelled: true),
            event("running", hours: -0.5, url: "https://zoom.us/j/333333333"),
        ]
        #expect(key(JoinSelector.choose(id: nil, from: events, now: now)) == "running")
        #expect(JoinSelector.choose(id: nil, from: [events[0], events[1]], now: now) == .nothingSoon)
    }

    @Test("An id picks that event, even one far off")
    func byID() {
        let events = [event("far", hours: 30, url: "https://zoom.us/j/111111111"), event("plain", hours: 1)]
        #expect(key(JoinSelector.choose(id: "far", from: events, now: now)) == "far")
        #expect(JoinSelector.choose(id: "plain", from: events, now: now) == .noLink)
        #expect(JoinSelector.choose(id: "missing", from: events, now: now) == .unknownEvent)
    }

    @Test("The messages are plain")
    func messages() async {
        let events = [event("a", hours: 1, url: "https://zoom.us/j/111111111"), event("b", hours: 1)]
        func run(_ id: String?, _ result: MeetingJoinResult = .openedApp) async -> String {
            await JoinCommand.join(id: id, events: events, now: now, joiner: Recorder(result: result))
        }
        #expect(await run("a") == "Opened Zoom for Event a.")
        #expect(await run("a", .openedWeb) == "Opened the Zoom link in the browser for Event a.")
        #expect(await run("a", .failed) == MeetingJoinText.failed)
        #expect(await run("b") == "That event has no meeting link.")
        #expect(await run("x") == "No event with that id was found. Ids are listed by `calopod events --ids`.")
        #expect(await JoinCommand.join(id: nil, events: [], now: now, joiner: Recorder(result: .openedApp))
            == "No event with a meeting link is on now or starts within 12 hours.")
    }

    @Test("Events output shows the link and keeps it in one piece")
    func humanOutput() throws {
        let link = "https://us02web.zoom.us/j/123456789?pwd=" + String(repeating: "a", count: 120)
        let payload = CommandPayload(status: "ok", message: "Events in the requested range.", count: 1, items: [
            CommandItem(id: "e", kind: "event", label: "Synthetic meeting", startsAt: "2026-10-09T09:00:00Z",
                        joinProvider: "Zoom", joinURL: link),
        ])
        let human = try OutputRenderer.render(command: "events", payload: payload, warnings: [], format: .human)
        #expect(human.contains("  Join: Zoom \(link)"))
        let json = try OutputRenderer.render(command: "events", payload: payload, warnings: [], format: .json)
        #expect(json.contains("\"joinProvider\""))
        #expect(json.contains("\"joinURL\""))
    }
}
#endif
