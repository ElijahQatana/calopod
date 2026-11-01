@testable import CalopodCommands
import CalopodStore
import Foundation
import Testing

@Suite("calopod hours")
struct HoursCommandTests {
    @Test("Set changes the named days and keeps the rest")
    func roundTrip() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let first = try HoursSetCommand.parse(["--days", "mon-thu", "--start", "8:30", "--end", "16:00"])
        try state.saveWorkingHours(first.resolve(state.workingHours()))
        let off = try HoursSetCommand.parse(["--days", "fri", "--off"])
        try state.saveWorkingHours(off.resolve(state.workingHours()))
        let hours = try state.workingHours()
        #expect(hours.day(isoWeekday: 2) == (try WorkingHours.Day(startMinute: 510, endMinute: 960)))
        #expect(hours.day(isoWeekday: 5) == nil && hours.day(isoWeekday: 7) == nil)
    }

    @Test("One time can change on a working day, and a day off needs both")
    func partial() throws {
        let current = WorkingHours.standard
        let later = try HoursSetCommand.parse(["--days", "weekdays", "--end", "18:00"]).resolve(current)
        #expect(later.day(isoWeekday: 1) == (try WorkingHours.Day(startMinute: 540, endMinute: 1080)))
        #expect(throws: (any Error).self) { try HoursSetCommand.parse(["--days", "sat", "--start", "10:00"]).resolve(current) }
        #expect(try HoursSetCommand.parse(["--days", "sat", "--start", "10:00", "--end", "12:00"]).resolve(current).day(isoWeekday: 6) != nil)
    }

    @Test("Bad days, times and empty options are refused")
    func parsing() throws {
        for arguments in [["--days", "mon"], ["--days", "mon", "--off", "--start", "9:00"], ["--days", "fri-mon", "--off"],
                          ["--days", "funday", "--off"], ["--days", "mon", "--start", "25:00"], ["--days", "mon", "--start", "9"]] {
            #expect(throws: (any Error).self) { try HoursSetCommand.parse(arguments).resolve(.standard) }
        }
        #expect(try HoursText.weekdays("sat,sun,mon-tue") == [6, 7, 1, 2])
        #expect(throws: (any Error).self) { try HoursSetCommand.parse(["--days", "mon", "--start", "17:00", "--end", "09:00"]).resolve(.standard) }
    }

    @Test("JSON lists all seven days with the time zone")
    func json() throws {
        let output = WorkingHoursOutput(.standard, timeZone: TimeZone(identifier: "Europe/London")!)
        #expect(output.timeZone == "Europe/London" && output.days.count == 7)
        #expect(output.days[0] == .init(weekday: "monday", working: true, start: "09:00", end: "17:00"))
        #expect(output.days[6] == .init(weekday: "sunday", working: false, start: nil, end: nil))
    }

    @Test("Focus takes minutes or hours and keeps the allowed range")
    func focus() throws {
        #expect(try HoursFocusCommand.parse(["90m"]).resolve().minutes == 90)
        #expect(try HoursFocusCommand.parse(["3h"]).resolve().minutes == 180)
        for length in ["10m", "25h", "2d", "2", "90s"] {
            #expect(throws: (any Error).self) { try HoursFocusCommand.parse([length]).resolve() }
        }
    }

    @Test("JSON carries the focus length next to the days")
    func focusJSON() throws {
        let payload = CommandPayload(status: "ok", message: "Working hours.", workingHours: WorkingHoursOutput(.standard, focusMinutes: 150))
        let json = try OutputRenderer.render(command: "hours", payload: payload, format: .json)
        #expect(json.contains("\"focusMinutes\" : 150") || json.contains("\"focusMinutes\":150"))
    }
}
