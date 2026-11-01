import CalopodSync
import Foundation
import Testing
@testable import CalopodCommands

@Suite("Free slot text")
struct FreeSlotTextTests {
    private func text(_ zone: String, _ windows: [(DateComponents, DateComponents)]) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let intervals = windows.map {
            AvailabilityInterval(kind: .free, start: calendar.date(from: $0.0)!, end: calendar.date(from: $0.1)!)
        }
        return FreeSlotText.text(intervals, timeZone: calendar.timeZone)
    }

    private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> DateComponents {
        DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)
    }

    @Test("One line per window, with the day and the zone")
    func lines() {
        let zone = "America/New_York"
        #expect(text(zone, [(at(11, 3, 14), at(11, 3, 16)), (at(11, 4, 10), at(11, 4, 12))])
            == "Tue Nov 3, 2:00 to 4:00 PM EST\nWed Nov 4, 10:00 AM to 12:00 PM EST")
        #expect(text(zone, [(at(7, 6, 9, 15), at(7, 6, 9, 45))]) == "Mon Jul 6, 9:15 to 9:45 AM EDT")
    }

    @Test("Clock edges around midnight and noon")
    func clockEdges() {
        let zone = "UTC"
        let cases: [(DateComponents, DateComponents, String)] = [
            (at(11, 3, 0), at(11, 3, 1), "Tue Nov 3, 12:00 to 1:00 AM GMT"),
            (at(11, 3, 11), at(11, 3, 12), "Tue Nov 3, 11:00 AM to 12:00 PM GMT"),
            (at(11, 3, 12), at(11, 3, 13), "Tue Nov 3, 12:00 to 1:00 PM GMT"),
            (at(11, 3, 22), at(11, 4, 0), "Tue Nov 3, 10:00 PM to 12:00 AM GMT"),
        ]
        for item in cases { #expect(text(zone, [(item.0, item.1)]) == item.2) }
    }

    @Test("A window across midnight shows both days")
    func acrossMidnight() {
        #expect(text("UTC", [(at(11, 3, 22), at(11, 4, 1))]) == "Tue Nov 3, 10:00 PM to Wed Nov 4, 1:00 AM GMT")
    }

    @Test("A zone that changes inside the window shows both")
    func zoneChange() {
        #expect(text("America/New_York", [(at(3, 8, 0, 30), at(3, 8, 4))])
            == "Sun Mar 8, 12:30 AM EST to 4:00 AM EDT")
        #expect(text("America/New_York", [(at(11, 1, 0, 30), at(11, 1, 4))])
            == "Sun Nov 1, 12:30 AM EDT to 4:00 AM EST")
    }

    @Test("No windows gives no text")
    func empty() {
        #expect(FreeSlotText.text([], timeZone: TimeZone(identifier: "UTC")!).isEmpty)
    }
}
