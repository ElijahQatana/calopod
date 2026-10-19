#if os(macOS)
import CalopodDomain
import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands

@Suite("Mac calendar schedule")
struct CalendarScheduleServiceTests {
    @Test("Reads overlaps, replies and copies from the local copy")
    func readsLocalCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = LocalStateRepository(database: try CalopodDatabase(path: root.appendingPathComponent("state.sqlite").path))
        try state.saveConnection(StoredConnection(
            id: "connection", configurationID: "config", provider: "google", displayLabel: "Example", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "connection", bindings: ["work", "main"].map {
            StoredCalendarBinding(
                id: $0, connectionID: "connection", providerCalendarID: $0, displayLabel: $0.capitalized,
                isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser)
        })
        func event(_ key: String, hour: Int, response: EventResponseState = .needsResponse) -> StoredNormalizedInstance {
            StoredNormalizedInstance(
                sourceKeyHash: key, connectionID: "connection", calendarBindingID: "work",
                providerEventID: key, recurrenceID: nil,
                startsAt: Date(timeIntervalSince1970: Double(hour) * 3600),
                endsAt: Date(timeIntervalSince1970: Double(hour + 2) * 3600),
                isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false,
                title: "Event \(key)", contentFingerprint: key, providerUpdatedAt: nil,
                url: "https://zoom.us/j/123456789",
                currentUserResponse: EventResponse(
                    state: response, evidence: .googleSelf,
                    actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])))
        }
        try state.applyEventRefresh(
            connectionID: "connection", calendarBindingID: "work",
            windowStart: Date(timeIntervalSince1970: 0), windowEnd: Date(timeIntervalSince1970: 200_000),
            instances: [event("a", hour: 10), event("b", hour: 11), event("c", hour: 20), event("d", hour: 21, response: .declined)],
            cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
        try state.saveArm(StoredArm(
            id: "arm", configurationID: "config", sourceBindingIDs: ["work"], targetBindingID: "main",
            ruleMode: .busy))
        try state.saveMirrorMapping(StoredMirrorMapping(
            mirrorKey: "m", armID: "arm", sourceKeyHash: "c", providerEventID: "copy-c",
            providerVersion: nil, desiredFingerprint: "x", ownershipKeyID: "k", updatedAt: Date()))

        let schedule = try CalendarScheduleService(makeRepository: { state }).schedule()

        let byID = Dictionary(uniqueKeysWithValues: schedule.events.map { ($0.id, $0) })
        #expect(byID["a"]?.overlaps == ["Event b"])
        #expect(byID["c"]?.overlaps == [])
        #expect(byID["a"]?.replies == [.yes, .no, .maybe])
        #expect(byID["c"]?.copiedTo == [ScheduleCopy(calendarName: "Main", fullDetails: false, calendarID: "main")])
        let copy = try #require(byID["copy:main:c"])
        #expect(copy.isCopy && copy.title == "Busy" && copy.calendarID == "main")
        #expect(copy.replies.isEmpty && copy.replyUnavailableReason != nil)
        #expect(byID["a"]?.meeting?.provider == .zoom)
        #expect(copy.meeting == nil)
        #expect(byID["d"]?.copyOverlaps == ["Busy"])
        #expect(byID["c"]?.copyOverlaps == [] && byID["a"]?.copyOverlaps == [])
        #expect(schedule.events.count == 5)
    }
}
#endif
