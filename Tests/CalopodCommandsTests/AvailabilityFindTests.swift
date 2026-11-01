import ArgumentParser
import CalopodSync
import Foundation
import Testing
@testable import CalopodCommands

@Suite("Availability find")
struct AvailabilityFindTests {
    @Test("Spans read a whole number and a unit")
    func spans() {
        let cases: [(text: String, count: Int?, unit: FindSpan.Unit?, seconds: TimeInterval?)] = [
            ("45m", 45, .minute, 2_700), ("2h", 2, .hour, 7_200), ("5d", 5, .day, nil),
            ("0m", nil, nil, nil), ("-5m", nil, nil, nil), ("45", nil, nil, nil), ("1.5h", nil, nil, nil), ("", nil, nil, nil),
        ]
        for item in cases {
            let span = FindSpan(item.text)
            #expect(span?.count == item.count)
            #expect(span?.unit == item.unit)
            #expect(span?.seconds == item.seconds)
        }
    }

    @Test("Duration and within are parsed from the command line")
    func parsing() throws {
        let command = try AvailabilityFindCommand.parse(["--duration", "45m", "--within", "5d", "--ignore-working-hours"])
        #expect(command.duration == "45m")
        #expect(command.within == "5d")
        #expect(command.ignoreWorkingHours)
        #expect(try AvailabilityFindCommand.parse(["--duration", "2h"]).within == nil)
    }

    @Test("Nonsense lengths and spans are refused")
    func refused() {
        let cases: [[String]] = [
            [], ["--duration", "0m"], ["--duration=-30m"], ["--duration", "45"], ["--duration", "1d"],
            ["--duration", "45m", "--within", "0d"], ["--duration", "45m", "--within=-1d"], ["--duration", "45m", "--within", "90m"],
            ["--duration", "45m", "--within", "400d"], ["--duration", "45m", "--within", "5d", "--day", "2026-03-02"],
        ]
        for arguments in cases {
            #expect(throws: (any Error).self) { try AvailabilityFindCommand.parse(arguments) }
        }
    }

    @Test("Plain availability still reads its own options")
    func defaultSubcommand() throws {
        #expect(try AvailabilityCommand.parseAsRoot(["--cached", "--day", "2026-03-02"]) is AvailabilityShowCommand)
        #expect(try AvailabilityCommand.parseAsRoot([]) is AvailabilityShowCommand)
        #expect(try AvailabilityCommand.parseAsRoot(["find", "--duration", "30m"]) is AvailabilityFindCommand)
    }

    @Test("The range runs from now, by calendar days")
    func window() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 6, hour: 12))!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!

        let five = try AvailabilityFindCommand.parse(["--duration", "1h", "--within", "5d", "--timezone", "America/New_York"])
        let range = try five.window(now: now)
        #expect(range.window.start == now)
        #expect(range.window.end == calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 12)))

        let week = try AvailabilityFindCommand.parse(["--duration", "1h", "--timezone", "America/New_York"]).window(now: now)
        #expect(week.window.end == calendar.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 12)))

        let day = try AvailabilityFindCommand.parse(["--duration", "1h", "--day", "2026-03-08", "--timezone", "America/New_York"])
        #expect(try day.window(now: now).window.start == sunday)

        let unknown = try AvailabilityFindCommand.parse(["--duration", "1h", "--timezone", "Nowhere/Synthetic"])
        #expect(throws: (any Error).self) { try unknown.window(now: now) }
    }

    @Test("JSON lists times only, next to the asked length")
    func json() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let items = AvailabilityFindCommand.items([AvailabilityInterval(kind: .free, start: start, end: start.addingTimeInterval(3_600))])
        let payload = CommandPayload(status: "ok", message: "Free windows of at least 45 min.", count: 1, items: items, lengthSeconds: 2_700)

        let json = try OutputRenderer.render(command: "availability.find", payload: payload, format: .json)

        #expect(items.map(\.availability) == ["free"])
        #expect(json.contains("\"schemaVersion\" : 1") || json.contains("\"schemaVersion\":1"))
        #expect(json.contains("\"lengthSeconds\" : 2700") || json.contains("\"lengthSeconds\":2700"))
        #expect(!json.contains("Synthetic"))
    }
}
