import CalopodCommands
import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Inbox attention date boundary integration")
struct InboxAttentionDateTests {
    @Test("Shared day and inclusive through parsing feed the same overlap query", arguments: ["2026-03-08", "2026-11-01"])
    func resolvedDays(_ day: String) throws {
        let localDay = try #require(try DateRangeResolver(day: day, timezone: "America/New_York").resolve(default: .none))
        let range = try #require(try DateRangeResolver(from: day, through: day, timezone: "America/New_York").resolve(default: .none))
        #expect(localDay == range)
        let start = range.window.start
        let end = range.window.end
        func event(_ key: String, start: Date, end: Date) -> InboxContextEvent {
            InboxContextEvent(event: StoredNormalizedInstance(sourceKeyHash: key, connectionID: "connection", calendarBindingID: "calendar", providerEventID: key, recurrenceID: nil,
                startsAt: start, endsAt: end, isAllDay: true, availability: "free", isCancelled: false, isPrivate: false,
                title: "Example event", contentFingerprint: "synthetic", providerUpdatedAt: nil, currentUserResponse: EventResponse(state: .needsResponse)))
        }
        let snapshot = InboxContextSnapshot(sources: [InboxContextSource(bindingID: "calendar", connectionID: "connection", provider: "google",
            coverage: InboxCoverage(startsAt: start.addingTimeInterval(-86400), endsAt: end.addingTimeInterval(86400), observedAt: start), healthStatus: "healthy")], events: [
                event("spanning", start: start.addingTimeInterval(-3600), end: end.addingTimeInterval(3600)),
                event("last-hour", start: end.addingTimeInterval(-3600), end: end),
                event("next-day", start: end, end: end.addingTimeInterval(3600)),
                event("previous-day", start: start.addingTimeInterval(-3600), end: start)
            ])
        let result = InboxAttentionQuery.evaluate(snapshot, filter: InboxAttentionFilter(window: range.window), freshnessCutoff: start)
        #expect(result.rows.map(\.item.event.sourceKeyHash) == ["spanning", "last-hour"])
        let noDate = try DateRangeResolver().resolve(default: .none)
        #expect(noDate == nil)
        #expect(InboxAttentionQuery.evaluate(snapshot, filter: InboxAttentionFilter(window: noDate?.window), freshnessCutoff: start).rows.count == 4)
    }
}
