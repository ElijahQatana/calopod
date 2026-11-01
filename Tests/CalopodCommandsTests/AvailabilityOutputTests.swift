import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing
@testable import CalopodCommands

@Suite("Availability output")
struct AvailabilityOutputTests {
    @Test("Busy time outside working hours is listed under its own kind")
    func outsideItems() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3_600) }
        let result = AvailabilityResult(
            busy: [AvailabilityInterval(kind: .busy, start: at(13), end: at(14.5))],
            free: [AvailabilityInterval(kind: .free, start: at(9), end: at(13))],
            workingWindows: [DateInterval(start: at(9), end: at(17))],
            outside: [
                OutsideInterval(side: .before, start: at(7), end: at(8)),
                OutsideInterval(side: .after, start: at(19.5), end: at(20)),
            ])

        let items = AvailabilityShowCommand.items(result)

        #expect(items.map(\.availability) == ["before-hours", "free", "busy", "after-hours"])
        #expect(items.map(\.label) == ["Before hours", "Free", "Busy", "After hours"])
    }

    @Test("JSON carries the totals next to the existing fields")
    func totalsJSON() throws {
        let payload = CommandPayload(
            status: "ok", message: "Availability in the requested range.",
            totals: AvailabilityTotalsOutput(freeSeconds: 19_800, busySeconds: 9_000, outsideSeconds: 5_400))

        let json = try OutputRenderer.render(command: "availability", payload: payload, format: .json)

        #expect(json.contains("\"totals\""))
        #expect(json.contains("\"outsideSeconds\" : 5400") || json.contains("\"outsideSeconds\":5400"))
    }

    @Test("Each local day gets its longest free stretch and the short flag")
    func days() throws {
        let start = Date(timeIntervalSince1970: 1_799_971_200)
        func at(_ hour: Double) -> Date { start.addingTimeInterval(hour * 3_600) }
        func free(_ from: Double, _ to: Double) -> AvailabilityInterval { AvailabilityInterval(kind: .free, start: at(from), end: at(to)) }
        let windows = [DateInterval(start: at(9), end: at(17)), DateInterval(start: at(33), end: at(41))]
        let result = AvailabilityResult(
            busy: [], free: [free(9, 10.5), free(12, 17), free(33, 41)], workingWindows: windows)
        let range = ResolvedDateRange(window: try SyncWindow(start: start, end: at(72)), timeZoneIdentifier: "UTC")

        let days = AvailabilityShowCommand.days(result, range: range, focus: 7_200)

        #expect(days == [
            AvailabilityDayOutput(date: "2027-01-15", longestFreeSeconds: 18_000, short: false),
            AvailabilityDayOutput(date: "2027-01-16", longestFreeSeconds: 28_800, short: false),
            AvailabilityDayOutput(date: "2027-01-17", longestFreeSeconds: 0, short: false),
        ])
        #expect(AvailabilityShowCommand.days(result, range: range, focus: 36_000).map(\.short) == [true, true, false])
    }

    @Test("JSON adds the days and keeps the totals")
    func daysJSON() throws {
        let payload = CommandPayload(
            status: "ok", message: "Availability in the requested range.",
            totals: AvailabilityTotalsOutput(freeSeconds: 19_800, busySeconds: 9_000, outsideSeconds: 5_400),
            days: [AvailabilityDayOutput(date: "2027-01-15", longestFreeSeconds: 7_200, short: false)], focusSeconds: 7_200)

        let json = try OutputRenderer.render(command: "availability", payload: payload, format: .json)

        for key in ["\"totals\"", "\"freeSeconds\"", "\"days\"", "\"date\" : \"2027-01-15\"", "\"longestFreeSeconds\" : 7200", "\"short\" : false", "\"focusSeconds\" : 7200"] {
            #expect(json.contains(key) || json.contains(key.replacingOccurrences(of: " : ", with: ":")))
        }
        #expect(json.contains("\"schemaVersion\" : 1") || json.contains("\"schemaVersion\":1"))
    }
}
