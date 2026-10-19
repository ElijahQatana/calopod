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

    func testBusyTimeOutsideWorkingHoursIsReportedButNotCountedAsFree() throws {
        let fixture = try MacFixture(count: 2)
        let state = fixture.state
        let service = AvailabilityService(makeRepository: { state })
        let report = try service.report(days: [day()], calendar: utc)[0]

        XCTAssertEqual(report.result.busy.count, 2)
        XCTAssertEqual(report.result.free.map(\.start), [day().addingTimeInterval(9 * 3600)])
        XCTAssertEqual(report.summary.freeSeconds, 8 * 3600)
        XCTAssertEqual(report.summary.busySeconds, 2000)
        XCTAssertEqual(report.summary.load, .mostlyFree)
    }

    func testADayOffHasNoFreeTimeAndStillShowsBusy() throws {
        let fixture = try MacFixture(count: 1)
        let state = fixture.state
        try state.saveWorkingHours(WorkingHours.standard.setting(isoWeekday: 4, to: nil))
        let report = try AvailabilityService(makeRepository: { state }).report(days: [day()], calendar: utc)[0]
        XCTAssertTrue(report.result.free.isEmpty)
        XCTAssertEqual(report.summary.load, .dayOff)
        XCTAssertEqual(report.summary.busySeconds, 1000)
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

    func testTheTimePickerRoundTripsAndShowsMidnightAsTheLastMinute() {
        XCTAssertEqual(WorkingHoursSection.minute(WorkingHoursSection.date(570)), 570)
        XCTAssertEqual(WorkingHoursSection.minute(WorkingHoursSection.date(1440)), 1439)
    }
}
