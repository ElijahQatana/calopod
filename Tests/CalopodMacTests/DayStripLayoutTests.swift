import CalopodCommands
import XCTest

@testable import CalopodMac

final class DayStripLayoutTests: XCTestCase {
    private let top = Date(timeIntervalSince1970: 1_792_000_800) // an exact hour

    private func entry(_ id: String, _ startMinute: Double, _ minutes: Double, focused: Bool = false) -> InboxContextEntry {
        InboxContextEntry(
            id: id, title: id, calendarID: "work", calendarName: "Work",
            startsAt: top.addingTimeInterval(startMinute * 60), endsAt: top.addingTimeInterval((startMinute + minutes) * 60),
            isFocused: focused, overlapsFocused: false)
    }

    func testOverlapsShareColumnsAndShortEventsKeepRoom() {
        let placed = Dictionary(uniqueKeysWithValues: DayStripLayout.blocks([
            entry("ops", 90, 60, focused: true), entry("sync", 90, 30), entry("late", 170, 5),
        ], windowStart: top).map { ($0.id, $0) })
        XCTAssertEqual(Set([placed["ops"]?.column, placed["sync"]?.column]), [0, 1])
        XCTAssertEqual(placed["ops"]?.columns, 2)
        XCTAssertEqual(placed["late"]?.columns, 1)
        XCTAssertEqual(placed["ops"]?.top, 90)
        XCTAssertGreaterThanOrEqual(placed["late"]?.height ?? 0, 30)
    }

    func testWindowAcrossMidnightStaysWhole() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let late = utc.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 0))!
        let item = InboxContextEntry(id: "x", title: "x", calendarID: "c", calendarName: "C",
                                     startsAt: late.addingTimeInterval(3600), endsAt: late.addingTimeInterval(5400),
                                     isFocused: true, overlapsFocused: false)
        XCTAssertEqual(DayStripLayout.blocks([item], windowStart: late).first?.top, 60)
    }

    func testAxisStartsOnAnHourAndEveryHourGetsAMark() {
        let axis = DayStripLayout.axis(start: top.addingTimeInterval(-90 * 60), end: top.addingTimeInterval(90 * 60))
        XCTAssertEqual(axis.start, top.addingTimeInterval(-120 * 60))
        XCTAssertEqual(axis.end, top.addingTimeInterval(120 * 60))
        XCTAssertEqual(DayStripLayout.hourMarks(from: axis.start, to: axis.end).count, 4)
        XCTAssertEqual(DayStripLayout.axis(start: top, end: top.addingTimeInterval(3 * 3600)).end, top.addingTimeInterval(3 * 3600))
    }

    func testHourMarksAndHeight() {
        let marks = DayStripLayout.hourMarks(from: top.addingTimeInterval(30 * 60), to: top.addingTimeInterval(210 * 60))
        XCTAssertEqual(marks.map(\.minutes), [30, 90, 150])
        XCTAssertEqual(DayStripLayout.height(forMinutes: 180), 270)
        XCTAssertEqual(DayStripLayout.height(forMinutes: 60), 260)
        XCTAssertEqual(DayStripLayout.height(forMinutes: 600), 340)
    }
}
