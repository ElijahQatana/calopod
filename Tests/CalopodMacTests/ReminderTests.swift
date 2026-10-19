import CalopodCommands
import CalopodDomain
import CalopodStore
import XCTest

@testable import CalopodMac

/// A stand-in for the notification center that keeps what it is given and never posts anything.
final class FakeReminderCenter: ReminderCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _permission = NotificationPermissionState.allowed
    private var _pending: [String: PlannedReminder] = [:]
    private var _added: [String] = []
    private var _removed: [String] = []

    var permissionState: NotificationPermissionState {
        get { lock.withLock { _permission } }
        set { lock.withLock { _permission = newValue } }
    }
    var pendingIDs: [String] { lock.withLock { _pending.keys.sorted() } }
    var added: [String] { lock.withLock { _added } }
    var removed: [String] { lock.withLock { _removed } }
    func reminder(_ id: String) -> PlannedReminder? { lock.withLock { _pending[id] } }
    /// A pending request that is not ours, which must be left alone.
    func seedForeign(_ id: String) { lock.withLock { _pending[id] = PlannedReminder(id: id, fireDate: .distantFuture, kind: .first, title: "", body: "", eventID: "", joinURL: nil) } }
    func clearLog() { lock.withLock { _added = []; _removed = [] } }

    func permission() async -> NotificationPermissionState { permissionState }
    func requestPermission() async -> Bool { permissionState = .allowed; return true }
    func pending() async -> [PendingReminder] {
        lock.withLock { _pending.values.map { PendingReminder(id: $0.id, fingerprint: $0.fingerprint) } }
    }
    func add(_ reminder: PlannedReminder) async { lock.withLock { _pending[reminder.id] = reminder; _added.append(reminder.id) } }
    func remove(ids: [String]) async { lock.withLock { ids.forEach { _pending[$0] = nil }; _removed += ids } }
}

final class ReminderPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US")
    private let zoom = MeetingLink.first(in: "https://example.zoom.us/j/123456789")

    private func event(
        _ id: String, in minutes: Double, title: String = "Team standup", calendar: String = "work",
        response: ScheduleResponse = .accepted, allDay: Bool = false, copy: Bool = false,
        location: String? = nil, link: Bool = false
    ) -> ScheduleEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return ScheduleEvent(
            id: id, calendarID: calendar, title: title, startsAt: start, endsAt: start.addingTimeInterval(1800),
            isAllDay: allDay, location: location, response: response, isCopy: copy, meeting: link ? zoom : nil)
    }

    private func schedule(_ events: [ScheduleEvent]) -> CalendarSchedule {
        CalendarSchedule(
            calendars: [ScheduleCalendar(id: "work", name: "Work", account: "a@example.com", provider: "google")],
            events: events)
    }

    private func plan(
        _ events: [ScheduleEvent], _ settings: NotificationSettings = .standard, at date: Date? = nil,
        ignored: Set<String> = []
    ) -> [PlannedReminder] {
        ReminderPlanner.plan(
            schedule: schedule(events), settings: settings, now: date ?? now, ignored: { ignored.contains($0) },
            calendarName: { $0.id == "work" ? "Work calendar" : $0.name }, timeZone: utc, locale: locale)
    }

    func testEachEventGetsAFirstAndAFinalReminder() {
        let planned = plan([event("e1", in: 30)])
        XCTAssertEqual(planned.map(\.kind), [.first, .final])
        XCTAssertEqual(planned.map(\.fireDate), [now.addingTimeInterval(20 * 60), now.addingTimeInterval(29 * 60)])
        XCTAssertEqual(planned[0].title, "Team standup, in 10 minutes")
        XCTAssertEqual(planned[1].title, "Team standup, in 1 minute")
        XCTAssertTrue(planned[0].body.contains("Work calendar"))
        XCTAssertEqual(Set(planned.map(\.id)).count, 2)
        XCTAssertEqual(planned[0].threadID, planned[1].threadID)
    }

    func testSkipsWhatTheNextCardSkips() {
        let events = [
            event("past", in: -20), event("running", in: -5), event("declined", in: 30, response: .declined),
            event("copy", in: 30, copy: true), event("allday", in: 30, allDay: true),
            event("ignored", in: 30, calendar: "old"), event("maybe", in: 30, response: .tentative),
        ]
        XCTAssertEqual(Set(plan(events, ignored: ["old"]).map(\.eventID)), ["maybe"])
    }

    func testOnlyRemindersStillAheadAreKept() {
        // Six minutes out: the 10 minute reminder has passed, the 1 minute one has not.
        XCTAssertEqual(plan([event("e", in: 6)]).map(\.kind), [.final])
        // Thirty seconds out nothing is left.
        XCTAssertTrue(plan([event("e", in: 0.5)]).isEmpty)
        // Beyond a day only the reminders that fire within a day are planned.
        XCTAssertEqual(plan([event("e", in: 24 * 60 + 5)]).map(\.kind), [.first])
        XCTAssertTrue(plan([event("e", in: 24 * 60 + 11)]).isEmpty)
    }

    func testSettingsDecideWhichRemindersExist() throws {
        let events = [event("e", in: 60)]
        XCTAssertEqual(plan(events, try .standard.changing(firstEnabled: false)).map(\.kind), [.final])
        XCTAssertEqual(plan(events, try .standard.changing(finalEnabled: false)).map(\.kind), [.first])
        XCTAssertTrue(plan(events, try .standard.changing(firstEnabled: false, finalEnabled: false)).isEmpty)
        XCTAssertTrue(plan(events, try .standard.changing(enabled: false)).isEmpty)
        let custom = plan(events, try .standard.changing(firstMinutes: 45, finalMinutes: 5))
        XCTAssertEqual(custom.map(\.fireDate), [now.addingTimeInterval(15 * 60), now.addingTimeInterval(55 * 60)])
    }

    func testHiddenTitlesLeaveNothingAboutTheEvent() throws {
        let hidden = plan([event("e", in: 30, title: "Salary review", location: "Room 4", link: true)], try .standard.changing(hideTitles: true))
        XCTAssertEqual(hidden[0].title, "Meeting starting in 10 minutes")
        for reminder in hidden {
            XCTAssertFalse((reminder.title + reminder.body).contains("Salary"))
            XCTAssertFalse(reminder.body.contains("Room 4"))
            XCTAssertFalse(reminder.body.contains("Work"))
        }
    }

    func testBodyShowsLocationOtherwiseJoin() {
        XCTAssertTrue(plan([event("a", in: 30, location: "Room 4")])[0].body.hasSuffix("Room 4"))
        XCTAssertTrue(plan([event("b", in: 30, link: true)])[0].body.hasSuffix("Join"))
        // A web address is not shown as a place.
        XCTAssertTrue(plan([event("c", in: 30, location: "https://example.zoom.us/j/1", link: true)])[0].body.hasSuffix("Join"))
        XCTAssertFalse(plan([event("d", in: 30)])[0].body.contains("Join"))
    }

    func testJoinIsOnlyOfferedWithALink() {
        let withLink = plan([event("a", in: 30, link: true)])[0]
        XCTAssertEqual(withLink.category, ReminderCategory.join)
        XCTAssertNotNil(withLink.joinURL)
        XCTAssertEqual(plan([event("b", in: 30)])[0].category, ReminderCategory.open)
    }

    func testIdsAreStableAndFollowTheStartTime() {
        let first = plan([event("e", in: 30)]).map(\.id)
        XCTAssertEqual(plan([event("e", in: 30)]).map(\.id), first)
        XCTAssertNotEqual(plan([event("e", in: 40)]).map(\.id), first)
    }

    func testAtMostOneHundredTwentyEightSoonestAreKept() throws {
        let many = (0..<80).map { event("e\($0)", in: 30 + Double($0)) }
        let planned = plan(many)
        XCTAssertEqual(planned.count, ReminderPlanner.limit)
        XCTAssertEqual(planned, planned.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) })
    }

    func testReminderThatLandsWithTheFinalIsReplacedByIt() throws {
        // Equal times cannot be saved, but a stored row could still hold them; the final one wins.
        let settings = try NotificationSettings(firstEnabled: false, firstMinutes: 5, finalMinutes: 5)
        XCTAssertEqual(plan([event("e", in: 30)], settings).map(\.kind), [.final])
    }
}

/// Lets a test change what a scheduler closure returns.
@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

final class ReminderReconcilerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, in minutes: Double, response: ScheduleResponse = .accepted, calendar: String = "work", title: String = "Planning") -> ScheduleEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return ScheduleEvent(id: id, calendarID: calendar, title: title, startsAt: start, endsAt: start.addingTimeInterval(1800), response: response)
    }

    @MainActor
    private func scheduler(
        _ center: FakeReminderCenter, events: @escaping @MainActor () -> [ScheduleEvent]?, settings: @escaping @MainActor () -> NotificationSettings = { .standard },
        ignored: @escaping @MainActor (String) -> Bool = { _ in false }
    ) -> ReminderScheduler {
        ReminderScheduler(
            center: center, settings: settings,
            schedule: { events().map { CalendarSchedule(calendars: [], events: $0) } }, ignored: ignored,
            shownName: { $0.name }, now: { [now] in now })
    }

    @MainActor
    func testAddsMissingRemindersAndNeverDuplicatesThem() async {
        let center = FakeReminderCenter()
        let runner = scheduler(center) { [self] in [event("a", in: 30), event("b", in: 60)] }
        await runner.reconcile()
        XCTAssertEqual(center.pendingIDs.count, 4)
        XCTAssertEqual(center.added.count, 4)
        center.clearLog()
        await runner.reconcile()
        await runner.reconcile()
        XCTAssertEqual(center.added, [])
        XCTAssertEqual(center.removed, [])
        XCTAssertEqual(center.pendingIDs.count, 4)
    }

    @MainActor
    func testConcurrentCallsAreFoldedTogether() async {
        let center = FakeReminderCenter()
        let runner = scheduler(center) { [self] in [event("a", in: 30)] }
        async let one: Void = runner.reconcile()
        async let two: Void = runner.reconcile()
        async let three: Void = runner.reconcile()
        _ = await (one, two, three)
        XCTAssertEqual(center.pendingIDs.count, 2)
        XCTAssertEqual(Set(center.added).count, center.added.count)
    }

    @MainActor
    func testMovedDeclinedAndRemovedEventsLoseTheirOldReminders() async {
        let center = FakeReminderCenter()
        let events = Box([event("moves", in: 30), event("declines", in: 40), event("goes", in: 50)])
        let runner = scheduler(center) { events.value }
        await runner.reconcile()
        let before = Set(center.pendingIDs)
        XCTAssertEqual(before.count, 6)

        events.value = [event("moves", in: 35), event("declines", in: 40, response: .declined)]
        await runner.reconcile()
        let after = Set(center.pendingIDs)
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after.allSatisfy { $0.contains("moves") })
        XCTAssertTrue(before.isDisjoint(with: after))
    }

    @MainActor
    func testChangingSettingsOrIgnoringACalendarUpdatesWhatIsPending() async throws {
        let center = FakeReminderCenter()
        let settings = Box(NotificationSettings.standard)
        let ignoredWork = Box(false)
        let runner = scheduler(center, events: { [self] in [event("a", in: 60)] }, settings: { settings.value }, ignored: { _ in ignoredWork.value })
        await runner.reconcile()
        XCTAssertEqual(center.pendingIDs.count, 2)

        settings.value = try settings.value.changing(firstMinutes: 20)
        await runner.reconcile()
        XCTAssertEqual(center.pendingIDs.count, 2)
        XCTAssertEqual(Set(center.pendingIDs.compactMap { center.reminder($0)?.fireDate }), [now.addingTimeInterval(40 * 60), now.addingTimeInterval(59 * 60)])

        settings.value = try settings.value.changing(hideTitles: true)
        await runner.reconcile()
        XCTAssertTrue(center.pendingIDs.allSatisfy { center.reminder($0)?.title.hasPrefix("Meeting starting") == true })

        ignoredWork.value = true
        await runner.reconcile()
        XCTAssertTrue(center.pendingIDs.isEmpty)
    }

    @MainActor
    func testAChangedTitleReplacesTheSameRequest() async {
        let center = FakeReminderCenter()
        let title = Box("Planning")
        let runner = scheduler(center) { [self] in [event("a", in: 30, title: title.value)] }
        await runner.reconcile()
        title.value = "Planning, moved to room 2"
        center.clearLog()
        await runner.reconcile()
        XCTAssertEqual(center.added.count, 2)
        XCTAssertEqual(center.pendingIDs.count, 2)
        XCTAssertTrue(center.pendingIDs.allSatisfy { center.reminder($0)?.title.contains("room 2") == true })
    }

    @MainActor
    func testOtherRequestsAreLeftAlone() async {
        let center = FakeReminderCenter()
        center.seedForeign("someone.else.1")
        let runner = scheduler(center) { [self] in [event("a", in: 30)] }
        await runner.reconcile()
        XCTAssertTrue(center.pendingIDs.contains("someone.else.1"))
        XCTAssertEqual(center.pendingIDs.count, 3)
    }

    @MainActor
    func testWithoutPermissionNothingIsKeptPending() async {
        let center = FakeReminderCenter()
        let runner = scheduler(center) { [self] in [event("a", in: 30)] }
        await runner.reconcile()
        center.permissionState = .denied
        await runner.reconcile()
        XCTAssertTrue(center.pendingIDs.isEmpty)
        center.permissionState = .allowed
        await runner.reconcile()
        XCTAssertEqual(center.pendingIDs.count, 2)
    }

    @MainActor
    func testBeforeTheFirstLoadNothingIsCleared() async {
        let center = FakeReminderCenter()
        let loaded = Box<[ScheduleEvent]?>([event("a", in: 30)])
        let runner = scheduler(center) { loaded.value }
        await runner.reconcile()
        loaded.value = nil
        await runner.reconcile()
        XCTAssertEqual(center.pendingIDs.count, 2)
    }
}

@MainActor
final class ReminderResponseTests: XCTestCase {
    private let link = "https://example.zoom.us/j/123456789"

    private final class Recorder: MeetingJoining, @unchecked Sendable {
        private let lock = NSLock()
        private var _joined: [MeetingLink] = []
        var joined: [MeetingLink] { lock.withLock { _joined } }
        func join(_ link: MeetingLink) async -> MeetingJoinResult { lock.withLock { _joined.append(link) }; return .openedWeb }
    }

    func testActionsMapToJoinOrOpen() {
        let info = [ReminderResponse.eventKey: "e1", ReminderResponse.joinKey: link]
        XCTAssertEqual(ReminderResponse.parse(actionIdentifier: ReminderActionID.open, info: info), .open(eventID: "e1"))
        XCTAssertEqual(ReminderResponse.parse(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", info: info), .open(eventID: "e1"))
        if case .join(let found, let id)? = ReminderResponse.parse(actionIdentifier: ReminderActionID.join, info: info) {
            XCTAssertEqual(id, "e1")
            XCTAssertEqual(found.provider, .zoom)
        } else {
            XCTFail("Join should map to a join")
        }
        // Without a usable link, Join falls back to opening the event; dismissing does nothing.
        XCTAssertEqual(ReminderResponse.parse(actionIdentifier: ReminderActionID.join, info: [ReminderResponse.eventKey: "e1"]), .open(eventID: "e1"))
        XCTAssertNil(ReminderResponse.parse(actionIdentifier: "com.apple.UNNotificationDismissActionIdentifier", info: info))
        XCTAssertNil(ReminderResponse.parse(actionIdentifier: ReminderActionID.open, info: [:]))
    }

    func testJoinOpensTheMeetingAndOpenWaitsForTheApp() async throws {
        let recorder = Recorder()
        let router = ReminderRouter(joiner: recorder)
        let meeting = try XCTUnwrap(MeetingLink.first(in: link))
        router.receive(.join(meeting, eventID: "e1"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.joined, [meeting])

        // Clicked before the app is ready: held, then delivered once, and the later ones go straight through.
        router.receive(.open(eventID: "e1"))
        router.receive(.open(eventID: "e2"))
        var opened: [String] = []
        router.attach { opened.append($0) }
        XCTAssertEqual(opened, ["e2"])
        router.receive(.open(eventID: "e3"))
        XCTAssertEqual(opened, ["e2", "e3"])
    }

    func testOpeningShowsTheEventInCalendarLikeTheMenuBarCard() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000 + 1800)
        let item = ScheduleEvent(id: "e1", calendarID: "work", title: "Planning", startsAt: start, endsAt: start.addingTimeInterval(1800))
        let suite = try XCTUnwrap(UserDefaults(suiteName: #function))
        suite.removePersistentDomain(forName: #function)
        let model = CalendarModel(defaults: suite, aliases: .isolated(), load: { CalendarSchedule(calendars: [], events: [item]) })
        await model.reload()
        let navigation = AppNavigation(environment: [:])
        var shown = 0
        ReminderNavigation.open("e1", schedule: model, navigation: navigation, show: { shown += 1 })
        XCTAssertEqual(navigation.selection, .calendar)
        XCTAssertEqual(model.selected?.id, "e1")
        XCTAssertEqual(shown, 1)

        // An event that is gone still brings Calendar forward.
        navigation.selection = .overview
        ReminderNavigation.open("missing", schedule: model, navigation: navigation, show: { shown += 1 })
        XCTAssertEqual(navigation.selection, .calendar)
        XCTAssertEqual(shown, 2)
    }
}

@MainActor
final class NotificationSettingsModelTests: XCTestCase {
    func testChangesAreSavedAndTellTheScheduler() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let model = NotificationSettingsModel(state: state)
        var changes = 0
        model.onChange = { changes += 1 }
        model.apply { try $0.changing(firstMinutes: 15) }
        XCTAssertEqual(try state.notificationSettings().firstMinutes, 15)
        XCTAssertEqual(changes, 1)
        model.apply { try $0.changing(firstMinutes: 15) }
        XCTAssertEqual(changes, 1)
    }

    func testFinalNotEarlierIsRefusedWithAPlainReason() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let model = NotificationSettingsModel(state: state)
        model.apply { try $0.changing(finalMinutes: 10) }
        XCTAssertEqual(model.settings, .standard)
        XCTAssertEqual(model.notice, NotificationSettings.orderExplanation)
        XCTAssertEqual(try state.notificationSettings(), .standard)
        model.apply { try $0.changing(hideTitles: true) }
        XCTAssertNil(model.notice)
    }

    func testStepperBoundsKeepTheOrder() throws {
        let model = NotificationSettingsModel(state: nil)
        XCTAssertEqual(model.firstRange, 2...120)
        XCTAssertEqual(model.finalRange, 1...9)
        model.apply { try $0.changing(firstEnabled: false) }
        XCTAssertEqual(model.finalRange, 1...120)
    }

    func testAChangeMadeByTheCommandLineIsPickedUp() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let model = NotificationSettingsModel(state: state)
        try state.saveNotificationSettings(try .standard.changing(hideTitles: true))
        XCTAssertTrue(model.current().hideTitles)
    }
}
