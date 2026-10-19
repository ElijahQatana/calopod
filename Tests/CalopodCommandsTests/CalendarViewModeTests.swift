import CalopodDomain
import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands

@Suite("Calendar view modes")
struct CalendarViewModeTests {
    private func arm(_ id: String, from: [String], to target: String, enabled: Bool = true) -> StoredArm {
        StoredArm(
            id: id, configurationID: "config", sourceBindingIDs: from, targetBindingID: target,
            ruleMode: .busy, isEnabled: enabled)
    }

    @Test("Roles follow active arms; both appears in both modes and unused only in All")
    func roles() {
        let roles = CalendarRoles(arms: [
            arm("a", from: ["work"], to: "hub"),
            arm("b", from: ["hub"], to: "home"),
            arm("paused", from: ["old"], to: "archive", enabled: false),
        ])
        let table: [(String, [CalendarViewMode])] = [
            ("work", [.all, .sources]),
            ("hub", [.all, .sources, .destinations]),
            ("home", [.all, .destinations]),
            ("old", [.all]),
            ("archive", [.all]),
            ("loose", [.all]),
        ]
        for (id, modes) in table {
            #expect(CalendarViewMode.allCases.filter { roles.includes(id, in: $0) } == modes, "\(id)")
        }
        #expect(CalendarViewMode.allCases.map(\.copiesShownByDefault) == [false, false, true])
    }

    @Test("The flag takes the three values and defaults to all")
    func flag() throws {
        #expect(try EventsCommand.parse([]).view == .all)
        for mode in CalendarViewMode.allCases {
            #expect(try EventsCommand.parse(["--view", mode.rawValue]).view == mode)
        }
        #expect(throws: (any Error).self) { try EventsCommand.parse(["--view", "other"]) }
        #expect(try EventsCommand.parse([]).copies == nil)
        #expect(try EventsCommand.parse(["--copies"]).copies == true)
        #expect(try EventsCommand.parse(["--no-copies"]).copies == false)
    }

    @Test("Destination copies come from active arms at the source's time")
    func copies() throws {
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
        let start = Date(timeIntervalSince1970: 36000)
        try state.applyEventRefresh(
            connectionID: "connection", calendarBindingID: "work",
            windowStart: Date(timeIntervalSince1970: 0), windowEnd: Date(timeIntervalSince1970: 200_000),
            instances: [StoredNormalizedInstance(
                sourceKeyHash: "e", connectionID: "connection", calendarBindingID: "work", providerEventID: "e",
                recurrenceID: nil, startsAt: start, endsAt: start.addingTimeInterval(3600), isAllDay: false,
                availability: "busy", isCancelled: false, isPrivate: false, title: "Planning",
                contentFingerprint: "e", providerUpdatedAt: nil)],
            cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
        let live = arm("live", from: ["work"], to: "main")
        try state.saveArm(live)
        try state.saveMirrorMapping(StoredMirrorMapping(
            mirrorKey: "m", armID: "live", sourceKeyHash: "e", providerEventID: "copy", providerVersion: nil,
            desiredFingerprint: "x", ownershipKeyID: "k", updatedAt: Date()))
        let range = ResolvedDateRange(
            window: try SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100_000)),
            timeZoneIdentifier: "UTC")

        let items = try destinationCopies(arms: [live], repository: state, into: ["main"], range: range)
        #expect(items.map(\.id) == ["copy:main:e"])
        #expect(items.first?.label == "Busy" && items.first?.parentID == "main")

        let paused = arm("live", from: ["work"], to: "main", enabled: false)
        #expect(try destinationCopies(arms: [paused], repository: state, into: ["main"], range: range).isEmpty)
        #expect(try destinationCopies(arms: [live], repository: state, into: ["work"], range: range).isEmpty)
    }
}
