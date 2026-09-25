import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Availability calculation")
struct AvailabilityCalculatorTests {
    @Test("Busy intervals are clamped and merged while free events are ignored")
    func mergedIntervals() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(100)
        let instances = [
            instance(id: "early", start: start.addingTimeInterval(-10), end: start.addingTimeInterval(20)),
            instance(id: "duplicate", start: start, end: start.addingTimeInterval(20)),
            instance(
                id: "free-event",
                start: start.addingTimeInterval(10),
                end: start.addingTimeInterval(30),
                availability: "free"
            ),
            instance(id: "overlap", start: start.addingTimeInterval(15), end: start.addingTimeInterval(40)),
            instance(
                id: "touching",
                start: start.addingTimeInterval(40),
                end: start.addingTimeInterval(50),
                availability: "tentative"
            ),
            instance(id: "late", start: start.addingTimeInterval(70), end: end.addingTimeInterval(20)),
        ]

        let result = AvailabilityCalculator.calculate(
            instances: instances,
            from: start,
            through: end
        )

        #expect(result.busy == [
            AvailabilityInterval(kind: .busy, start: start, end: start.addingTimeInterval(50)),
            AvailabilityInterval(kind: .busy, start: start.addingTimeInterval(70), end: end),
        ])
        #expect(result.free == [
            AvailabilityInterval(
                kind: .free,
                start: start.addingTimeInterval(50),
                end: start.addingTimeInterval(70)
            ),
        ])
    }

    @Test("An empty calendar leaves the whole window free")
    func emptyWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(100)

        let result = AvailabilityCalculator.calculate(
            instances: [],
            from: start,
            through: end
        )

        #expect(result.busy.isEmpty)
        #expect(result.free == [AvailabilityInterval(kind: .free, start: start, end: end)])
    }

    private func instance(
        id: String,
        start: Date,
        end: Date,
        availability: String = "busy"
    ) -> StoredNormalizedInstance {
        StoredNormalizedInstance(
            sourceKeyHash: id,
            connectionID: "connection",
            calendarBindingID: "calendar",
            providerEventID: id,
            recurrenceID: nil,
            startsAt: start,
            endsAt: end,
            isAllDay: false,
            availability: availability,
            isCancelled: false,
            isPrivate: false,
            title: "Synthetic event",
            contentFingerprint: "fingerprint-\(id)",
            providerUpdatedAt: nil
        )
    }
}
