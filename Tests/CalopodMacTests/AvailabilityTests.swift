import CalopodStore
import CalopodSync
import Foundation
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class AvailabilityTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 1 January 1970 is a Thursday. The fixture's events sit at 02:46 and 06:20 UTC.
    private func day(_ offset: Int = 0) -> Date { Date(timeIntervalSince1970: Double(offset) * 86_400) }

    func testBusyTimeOutsideWorkingHoursIsReportedSeparately() throws {
        let fixture = try MacFixture(count: 2)
        let state = fixture.state
        let service = AvailabilityService(makeRepository: { state })
        let report = try service.report(days: [day()], calendar: utc)[0]

        XCTAssertTrue(report.result.busy.isEmpty)
        XCTAssertEqual(report.result.outside.map(\.side), [.before, .before])
        XCTAssertEqual(report.result.free.map(\.start), [day().addingTimeInterval(9 * 3600)])
        XCTAssertEqual(report.summary.freeSeconds, 8 * 3600)
        XCTAssertEqual(report.summary.busySeconds, 0)
        XCTAssertEqual(report.summary.outsideSeconds, 2000)
        XCTAssertEqual(report.summary.load, .mostlyFree)
    }

    func testADayOffHasNoFreeTimeAndAllMeetingsAreOutside() throws {
        let fixture = try MacFixture(count: 1)
        let state = fixture.state
        try state.saveWorkingHours(WorkingHours.standard.setting(isoWeekday: 4, to: nil))
        let report = try AvailabilityService(makeRepository: { state }).report(days: [day()], calendar: utc)[0]
        XCTAssertTrue(report.result.free.isEmpty)
        XCTAssertEqual(report.summary.load, .dayOff)
        XCTAssertEqual(report.summary.busySeconds, 0)
        XCTAssertEqual(report.summary.outsideSeconds, 1000)
        XCTAssertEqual(report.result.outside.map(\.side), [.dayOff])
    }

    func testStepKeepsTheWeekdayAndReloads() async throws {
        let model = AvailabilityModel(calendar: utc, now: { self.day() }, load: { days in
            days.map { start in
                let range = DateInterval(start: start, duration: 86_400), result = AvailabilityResult(busy: [], free: [])
                return AvailabilityDayReport(day: range, result: result, summary: AvailabilityDay(result, day: range))
            }
        })
        XCTAssertEqual(model.days.count, 7)
        XCTAssertEqual(utc.component(.weekday, from: model.selected), 5)
        await model.step(1)
        XCTAssertEqual(utc.component(.weekday, from: model.selected), 5)
        XCTAssertEqual(model.selected, utc.date(byAdding: .day, value: 7, to: day()))
        XCTAssertEqual(model.reports.first?.day.start, model.weekStart)
        XCTAssertNotNil(model.selectedReport)
        await model.goToToday()
        XCTAssertEqual(model.selected, day())
    }

    func testFindListsTheShownWeeksWindowsThatAreLongEnough() async {
        var clock = day()
        let model = AvailabilityModel(calendar: utc, now: { clock }, load: { days in
            days.map { start in
                // Free 9:00 to 10:30 and 13:00 to 17:00 on each day.
                let free = [(9.0, 10.5), (13.0, 17.0)].map {
                    AvailabilityInterval(kind: .free, start: start.addingTimeInterval($0.0 * 3600), end: start.addingTimeInterval($0.1 * 3600))
                }
                let range = DateInterval(start: start, duration: 86_400), result = AvailabilityResult(busy: [], free: free)
                return AvailabilityDayReport(day: range, result: result, summary: AvailabilityDay(result, day: range))
            }
        })
        await model.reload()
        clock = day(-7)
        for (text, count, valid) in [("", 0, false), ("soon", 0, false), ("2h", 7, true), (" 90m ", 14, true), ("5h", 0, true)] {
            model.findText = text
            XCTAssertEqual(model.found.count, count, text)
            XCTAssertEqual(model.findSeconds != nil, valid, text)
        }
        // Time already gone does not count: Thursday's morning window is too short by then.
        clock = day().addingTimeInterval(10 * 3600)
        model.findText = "90m"
        XCTAssertEqual(model.found.first?.start, day().addingTimeInterval(13 * 3600))
    }

    func testCopyTextHasEveryWindowFoundAndNothingWhenThereAreNone() async {
        var clock = day()
        let model = AvailabilityModel(calendar: utc, now: { clock }, load: { days in
            days.prefix(2).map { start in
                let free = [AvailabilityInterval(kind: .free, start: start.addingTimeInterval(9 * 3600), end: start.addingTimeInterval(11 * 3600))]
                let range = DateInterval(start: start, duration: 86_400), result = AvailabilityResult(busy: [], free: free)
                return AvailabilityDayReport(day: range, result: result, summary: AvailabilityDay(result, day: range))
            }
        })
        await model.reload()
        clock = day(-7)
        model.findText = "1h"
        XCTAssertEqual(model.foundText, "Sun Dec 28, 9:00 to 11:00 AM GMT\nMon Dec 29, 9:00 to 11:00 AM GMT")
        model.findText = "3h"
        XCTAssertEqual(model.foundText, "")
    }

    func testAFailedReadSaysSoAndClearsOldDays() async {
        struct Broken: Error {}
        let model = AvailabilityModel(calendar: utc, now: { self.day() }, load: { _ in throw Broken() })
        await model.reload()
        XCTAssertTrue(model.loadFailed)
        XCTAssertTrue(model.reports.isEmpty)
    }
}

@MainActor
final class WorkingHoursModelTests: XCTestCase {
    func testEditsAreSavedAndTellAvailability() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let model = WorkingHoursModel(state: state)
        var changes = 0
        model.onChange = { changes += 1 }
        model.setStart(480, isoWeekday: 2)
        model.setWorking(false, isoWeekday: 3)
        model.setWorking(true, isoWeekday: 6)
        let saved = try state.workingHours()
        XCTAssertEqual(saved.day(isoWeekday: 2)?.startMinute, 480)
        XCTAssertNil(saved.day(isoWeekday: 3))
        XCTAssertEqual(saved.day(isoWeekday: 6)?.endMinute, 1020)
        XCTAssertEqual(changes, 3)
        model.setStart(480, isoWeekday: 2)
        XCTAssertEqual(changes, 3)
    }

    func testAnEndBeforeTheStartIsRefusedWithAReason() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let model = WorkingHoursModel(state: state)
        model.setEnd(300, isoWeekday: 1)
        XCTAssertEqual(model.hours, .standard)
        XCTAssertEqual(model.notice, WorkingHoursError.invalidTimes.localizedDescription)
        model.setEnd(1080, isoWeekday: 1)
        XCTAssertNil(model.notice)
    }

    func testAChangeMadeByTheCommandLineIsPickedUp() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let model = WorkingHoursModel(state: state)
        try state.saveWorkingHours(WorkingHours(days: [1: WorkingHours.Day(startMinute: 600, endMinute: 660)]))
        model.reload()
        XCTAssertEqual(model.hours.days.count, 1)
    }

    func testTheFocusLengthIsSavedPickedUpAndChecked() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let model = WorkingHoursModel(state: state)
        var changes = 0
        model.onChange = { changes += 1 }
        model.setFocus(minutes: 90)
        model.setFocus(minutes: 90)
        XCTAssertEqual(try state.focusSettings().minutes, 90)
        XCTAssertEqual(changes, 1)
        model.setFocus(minutes: 5)
        XCTAssertEqual(model.focus.minutes, 90)
        XCTAssertNotNil(model.notice)
        try state.saveFocusSettings(FocusSettings(minutes: 180))
        model.reload()
        XCTAssertEqual(model.focus.minutes, 180)
    }

    func testTheTimePickerRoundTripsAndShowsMidnightAsTheLastMinute() {
        XCTAssertEqual(WorkingHoursSection.minute(WorkingHoursSection.date(570)), 570)
        XCTAssertEqual(WorkingHoursSection.minute(WorkingHoursSection.date(1440)), 1439)
    }
}
