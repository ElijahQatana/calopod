import CalopodCommands
@testable import CalopodStore
import XCTest

@testable import CalopodMac

@MainActor
final class CalendarSkipTests: XCTestCase {
    func testDontCopyAndCopyAgainChangeOnlyTheSavedSkips() async throws {
        let state = LocalStateRepository(database: try .inMemory())
        try state.saveConnection(StoredConnection(id: "connection", configurationID: "config", provider: "google", displayLabel: "Example", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "connection", bindings: [
            StoredCalendarBinding(id: "work", connectionID: "connection", providerCalendarID: "work", displayLabel: "Work", isSelected: true, isReadOnly: false)])
        let start = Date(timeIntervalSince1970: 2000)
        try state.applyEventRefresh(
            connectionID: "connection", calendarBindingID: "work", windowStart: .distantPast, windowEnd: .distantFuture,
            instances: [StoredNormalizedInstance(
                sourceKeyHash: "a", connectionID: "connection", calendarBindingID: "work", providerEventID: "a", recurrenceID: nil,
                startsAt: start, endsAt: start.addingTimeInterval(3600), isAllDay: false, availability: "busy", isCancelled: false,
                isPrivate: false, title: "Example", contentFingerprint: "a", providerUpdatedAt: nil)],
            cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
        let event = ScheduleEvent(id: "a", calendarID: "work", title: "Example", startsAt: start, endsAt: start.addingTimeInterval(3600))
        let model = CalendarModel(
            defaults: UserDefaults(suiteName: "skip-\(UUID().uuidString)")!, aliases: .isolated(), state: state,
            load: { CalendarSchedule(calendars: [], events: [event], roles: CalendarRoles()) })

        await model.setSkipped(true, event)
        XCTAssertEqual(try state.eventSkips().count, 1)
        await model.setSkipped(false, event)
        XCTAssertTrue(try state.eventSkips().isEmpty)
    }
}
