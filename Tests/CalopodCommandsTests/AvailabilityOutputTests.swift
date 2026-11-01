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
}
