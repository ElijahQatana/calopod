import CalopodDomain
import CalopodSnapshot
import Foundation
import Testing

@testable import Calopod

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let zoom = "https://example.zoom.us/j/123456789"

private func event(
    _ id: String, in hours: Double, allDay: Bool = false, response: EventResponseState = .accepted,
    title: String? = "Planning", location: String? = nil, join: String? = nil
) -> CalendarEvent {
    CalendarEvent(
        id: id, calendarID: "work", title: title, startsAt: now.addingTimeInterval(hours * 3600),
        endsAt: now.addingTimeInterval((hours + 1) * 3600), isAllDay: allDay, location: location, response: response, joinURL: join)
}

private func settings(
    enabled: Bool = true, first: Int? = 10, final: Int? = 1, hide: Bool = false
) -> ReminderSettings {
    ReminderSettings(
        enabled: enabled, firstEnabled: first != nil, firstMinutes: first ?? 10, finalEnabled: final != nil,
        finalMinutes: final ?? 1, hideTitles: hide)
}

private func snapshot(_ events: [CalendarEvent], _ reminders: ReminderSettings? = settings()) -> Snapshot {
    Snapshot(
        publishedAt: now, inbox: [], availability: [],
        days: [CalendarDay(day: "2027-01-15", timeZoneIdentifier: "UTC", events: events)], reminders: reminders,
        calendars: [CalendarEntry(id: "work", name: "Work", colorIndex: 6)], status: SyncStatus(lastSyncAt: now))
}

private func plan(_ snapshot: Snapshot) -> [PlannedReminder] {
    ReminderPlan.plan(snapshot: snapshot, now: now, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US"))
}

struct ReminderPlanTests {
    @Test func usesTheMacsLeadTimes() {
        let planned = plan(snapshot([event("a", in: 3)]))
        #expect(planned.map(\.fireDate) == [now.addingTimeInterval(3 * 3600 - 600), now.addingTimeInterval(3 * 3600 - 60)])
        #expect(planned.map(\.title) == ["Planning, in 10 minutes", "Planning, in 1 minute"])
        #expect(Set(planned.map(\.id)).count == 2 && planned.allSatisfy { $0.id.hasPrefix(ReminderPlan.idPrefix) })
        #expect(plan(snapshot([event("a", in: 3)], settings(first: 30, final: nil))).map(\.fireDate) == [now.addingTimeInterval(3 * 3600 - 1800)])
    }

    @Test func hiddenTitlesShowOnlyTheTime() {
        let planned = plan(snapshot([event("a", in: 3, location: "Room 4", join: zoom)], settings(hide: true)))
        #expect(planned.first?.title == "Meeting starting in 10 minutes")
        #expect(planned.allSatisfy { !$0.body.contains("Work") && !$0.body.contains("Room") && !$0.body.contains("Planning") })
        #expect(plan(snapshot([event("p", in: 3, title: nil)])).first?.title == "Busy, in 10 minutes")
    }

    @Test func bodyHasCalendarAndPlaceOrJoin() {
        #expect(plan(snapshot([event("a", in: 3, location: "Room 4")])).first?.body.hasSuffix("Work · Room 4") == true)
        #expect(plan(snapshot([event("a", in: 3, join: zoom)])).first?.body.hasSuffix("Work · Join") == true)
    }

    @Test func joinLinkIsTheOneTheReminderUses() {
        let snap = snapshot([event("a", in: 3, join: zoom), event("b", in: 4, join: "http://example.com/m"), event("c", in: 5)])
        #expect(snap.joinLink(forEvent: "a") == plan(snap).first?.joinURL && snap.joinLink(forEvent: "a") != nil)
        #expect(snap.joinLink(forEvent: "b") == nil && snap.joinLink(forEvent: "c") == nil && snap.joinLink(forEvent: "x") == nil)
    }

    @Test func skipsWhatHasStartedOrAlreadyPassed() {
        #expect(plan(snapshot([event("started", in: -0.5)])).isEmpty)
        // Five minutes away: the 10 minute reminder is past, the 1 minute one is still ahead.
        let soon = plan(snapshot([event("soon", in: 5.0 / 60)]))
        #expect(soon.map(\.title) == ["Planning, in 1 minute"])
    }

    @Test func keepsOnlyTheNextDay() {
        #expect(plan(snapshot([event("far", in: 25)])).isEmpty)
        // The 10 minute reminder is inside the day, the 1 minute one is just past it.
        let edge = plan(snapshot([event("edge", in: 24 + 5.0 / 60)]))
        #expect(edge.map(\.title) == ["Planning, in 10 minutes"])
    }

    @Test func switchesOffMeanNoReminders() {
        let events = [event("a", in: 3)]
        #expect(plan(snapshot(events, settings(enabled: false))).isEmpty)
        #expect(plan(snapshot(events, settings(first: nil, final: nil))).isEmpty)
        #expect(plan(snapshot(events, nil)).isEmpty)
    }

    @Test func followsTheMacsEligibilityRule() {
        let events = [event("allDay", in: 3, allDay: true), event("declined", in: 3, response: .declined), event("maybe", in: 3, response: .tentative)]
        #expect(Set(plan(snapshot(events)).map(\.eventID)) == ["maybe"])
    }

    @Test func aMultiDayEventIsPlannedOnce() {
        var both = snapshot([event("a", in: 3)])
        both.days.append(CalendarDay(day: "2027-01-16", timeZoneIdentifier: "UTC", events: [event("a", in: 3)]))
        #expect(plan(both).count == 2)
    }

    @Test func joinNeedsAnHttpsLink() {
        #expect(plan(snapshot([event("a", in: 3, join: zoom)])).first?.category == ReminderPlan.joinCategory)
        for link in ["http://example.com/j/1", "zoommtg://example.zoom.us/join", "not a link"] {
            let planned = plan(snapshot([event("a", in: 3, join: link)]))
            #expect(planned.first?.category == ReminderPlan.openCategory && planned.first?.joinURL == nil)
        }
    }

    @Test func summaryTellsWhatTheMacChose() {
        #expect(ReminderPlan.summary(settings()) == "Set on your Mac: 10 minutes and 1 minute before a meeting, with titles shown.")
        #expect(ReminderPlan.summary(settings(enabled: false)).hasPrefix("Reminders are off on your Mac"))
        #expect(ReminderPlan.summary(nil).hasPrefix("Your Mac hasn't shared"))
    }
}

struct ReminderResponseTests {
    @Test func tapsMapToActions() {
        let info = [ReminderResponse.eventKey: "a", ReminderResponse.joinKey: zoom]
        let url = URL(string: zoom)!
        #expect(ReminderResponse.parse(actionIdentifier: ReminderResponse.joinAction, info: info) == .join(url, eventID: "a"))
        #expect(ReminderResponse.parse(actionIdentifier: ReminderResponse.openAction, info: info) == .open(eventID: "a"))
        #expect(ReminderResponse.parse(actionIdentifier: ReminderResponse.joinAction, info: [ReminderResponse.eventKey: "a"]) == .open(eventID: "a"))
        #expect(ReminderResponse.parse(actionIdentifier: "com.apple.UNNotificationDismissActionIdentifier", info: info) == nil)
        #expect(ReminderResponse.parse(actionIdentifier: ReminderResponse.openAction, info: [:]) == nil)
    }
}

private actor FakeCenter: ReminderCenter {
    var state: NotificationPermission
    var pending: [String: PlannedReminder] = [:]
    var foreign: Set<String> = ["other.notification"]

    init(_ state: NotificationPermission) { self.state = state }

    func permission() -> NotificationPermission { state }
    func requestPermission() -> Bool { state = .allowed; return true }
    func pendingIDs() -> [String] { Array(pending.keys) + foreign }
    func add(_ reminder: PlannedReminder) { pending[reminder.id] = reminder }
    func remove(ids: [String]) { ids.forEach { pending[$0] = nil } }
}

@MainActor
struct RemindersTests {
    private func reminders(_ center: FakeCenter) -> Reminders {
        Reminders(center: center, defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { now })
    }

    @Test func schedulesThenFollowsTheSnapshotAndTheSwitch() async {
        let center = FakeCenter(.allowed)
        let model = reminders(center)
        #expect(model.isOn)
        let phase = { (events: [CalendarEvent]) in SnapshotStore.Phase.content(snapshot(events), offline: false) }
        await model.update(for: phase([event("a", in: 3), event("b", in: 4)]))
        #expect(await center.pending.count == 4)
        // An event the Mac no longer lists loses its reminders; other apps' notifications stay.
        await model.update(for: phase([event("a", in: 3)]))
        #expect(Set(await center.pending.values.map(\.eventID)) == ["a"])
        model.isOn = false
        // The switch reconciles in its own task.
        for _ in 0..<100 where !(await center.pending.isEmpty) { try? await Task.sleep(for: .milliseconds(20)) }
        let left = await center.pending, others = await center.foreign
        #expect(left.isEmpty && others == ["other.notification"])
    }

    @Test func needsPermissionAndKeepsRemindersWhenNothingWasRead() async {
        let center = FakeCenter(.notDetermined)
        let model = reminders(center)
        await model.update(for: .content(snapshot([event("a", in: 3)]), offline: false))
        #expect(await center.pending.isEmpty && model.permission == .notDetermined)
        await model.requestPermission()
        #expect(await center.pending.count == 2 && model.permission == .allowed)
        await model.update(for: .failed)
        await model.update(for: .signedOut)
        #expect(await center.pending.count == 2)
        await model.update(for: .sharingOff)
        #expect(await center.pending.isEmpty)
    }

    @Test func deniedPermissionSchedulesNothing() async {
        let center = FakeCenter(.denied)
        let model = reminders(center)
        await model.update(for: .content(snapshot([event("a", in: 3)]), offline: false))
        #expect(await center.pending.isEmpty && model.permission == .denied)
    }
}
