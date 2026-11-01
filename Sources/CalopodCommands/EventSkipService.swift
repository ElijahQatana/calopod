import ArgumentParser
import CalopodStore
import Foundation

/// Skips are kept on this Mac only. The event is not changed and nothing is sent to a provider.
public enum EventSkipService {
    public static func skip(
        eventID: String, wholeSeries: Bool, repository: LocalStateRepository, now: Date = Date()
    ) throws -> String {
        guard let event = try repository.cachedEvent(sourceKeyHash: eventID) else {
            throw ValidationError("No event with that id was found. Ids are listed by `calopod events --ids`.")
        }
        guard !wholeSeries || event.providerSeriesID != nil else { throw ValidationError("That event is not part of a series.") }
        let isEventKit = try repository.connection(id: event.connectionID)?.provider == "eventkit"
        try repository.addEventSkip(EventSkip(event, wholeSeries: wholeSeries, isEventKit: isEventKit, now: now))
        return "Calopod will not copy \(wholeSeries ? "this series" : "this event"). The event itself is unchanged."
    }

    /// Takes an event id or an id from the skipped list. Removes every skip that covers the event.
    public static func unskip(_ id: String, repository: LocalStateRepository) throws -> String {
        let event = try repository.cachedEvent(sourceKeyHash: id)
        let covering = try repository.eventSkips().filter { $0.id == id || event.map($0.matches) == true }
        guard !covering.isEmpty else { throw ValidationError("That event is not skipped.") }
        for skip in covering { try repository.removeEventSkip(skip) }
        return "Calopod will copy it again from the next sync."
    }

    public static func isSkipped(eventID: String, repository: LocalStateRepository) throws -> Bool {
        guard let event = try repository.cachedEvent(sourceKeyHash: eventID) else { return false }
        return try repository.eventSkips().contains { $0.matches(event) }
    }

    /// A skip with its event when it is in the synced range.
    public static func skipped(repository: LocalStateRepository) throws -> [(skip: EventSkip, event: StoredNormalizedInstance?)] {
        let skips = try repository.eventSkips()
        let events = try repository.normalizedInstances(
            calendarBindingIDs: Array(Set(skips.map(\.calendarBindingID))), from: .distantPast, through: .distantFuture)
        return skips.map { skip in (skip, events.first { skip.matches($0) }) }
    }
}
