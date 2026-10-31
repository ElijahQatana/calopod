import CalopodDomain
import CalopodStore
import Foundation

extension ArmPadding {
    func padded(of event: StoredNormalizedInstance) -> (startsAt: Date, endsAt: Date) {
        padded(
            startsAt: event.startsAt, endsAt: event.endsAt, isAllDay: event.isAllDay,
            location: event.location, url: event.url, notes: event.notes
        )
    }
}

extension AvailabilityCalculator {
    /// Copies are left out of Availability, so the time they pad is added to the events they copy.
    public static func withPadding(
        _ instances: [StoredNormalizedInstance], arms: [StoredArm]
    ) -> [StoredNormalizedInstance] {
        let padded = arms.filter { $0.isEnabled && !$0.effectivePadding.isEmpty }
        guard !padded.isEmpty else { return instances }
        return instances.map { event in
            let spans = padded.filter { $0.sourceBindingIDs.contains(event.calendarBindingID) && $0.filters.copies(event) }
                .map { $0.effectivePadding.padded(of: event) }
            guard let start = spans.map(\.startsAt).min(), let end = spans.map(\.endsAt).max(),
                  start < event.startsAt || end > event.endsAt else { return event }
            return event.spanning(startsAt: min(start, event.startsAt), endsAt: max(end, event.endsAt))
        }
    }
}
