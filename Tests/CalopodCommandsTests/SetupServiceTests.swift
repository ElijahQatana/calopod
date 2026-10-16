#if os(macOS)
import CalopodDomain
import CalopodRuntime
import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands

@Suite("Mac setup service")
struct SetupServiceTests {
    private func makeService() throws -> (SetupService, LocalStateRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let location = try CalopodStateLocation(
            environment: ["CALOPOD_STATE_PATH": root.appendingPathComponent("state.sqlite").path]
        )
        let environment = try CalopodRuntimeEnvironment(
            variables: [:],
            stateLocation: location,
            executableURL: root.appendingPathComponent("calopod")
        )
        let repository = try environment.repository()
        try repository.saveConnection(StoredConnection(
            id: "mac", configurationID: "default", provider: "eventkit",
            displayLabel: "Calendars on this Mac", isEnabled: true
        ))
        try repository.replaceCalendarBindings(connectionID: "mac", bindings: [
            StoredCalendarBinding(id: "work", connectionID: "mac", providerCalendarID: "w",
                displayLabel: "Work", isSelected: false, isReadOnly: false),
            StoredCalendarBinding(id: "main", connectionID: "mac", providerCalendarID: "m",
                displayLabel: "Main", isSelected: false, isReadOnly: false),
        ])
        return (SetupService(makeRepository: { repository }), repository, root)
    }

    @Test("selecting calendars and configuring the Main calendar shows up in the snapshot")
    func mainCalendarRoundTrip() throws {
        let (service, _, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        try service.setSelected(calendarID: "work", selected: true)
        try service.setSelected(calendarID: "main", selected: true)
        #expect(try service.snapshot().hasMainCalendar == false)

        try service.configureMain(sourceIDs: ["work"], targetID: "main")
        let snapshot = try service.snapshot()
        let main = try #require(snapshot.arms.first)
        #expect(snapshot.hasMainCalendar)
        #expect(main.sourceNames == ["Work"])
        #expect(main.targetName == "Main")
        #expect(main.rule == .fullDetails)
    }

    @Test("an unselected source is rejected with a plain message")
    func unselectedSourceIsRejected() throws {
        let (service, _, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        try service.setSelected(calendarID: "main", selected: true)
        #expect(throws: (any Error).self) {
            try service.configureMain(sourceIDs: ["work"], targetID: "main")
        }
        #expect(try service.snapshot().arms.isEmpty)
    }

    @Test("arm rule, enablement and removal change configuration only")
    func armLifecycle() throws {
        let (service, _, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        try service.setSelected(calendarID: "work", selected: true)
        try service.setSelected(calendarID: "main", selected: true)
        try service.addArm(sourceIDs: ["work"], targetID: "main", rule: .busy, name: "Busy copy")
        let id = try #require(try service.snapshot().arms.first?.id)

        try service.setRule(armID: id, rule: .fullDetails)
        try service.setArmEnabled(armID: id, enabled: false)
        let arm = try #require(try service.snapshot().arms.first)
        #expect(arm.rule == .fullDetails)
        #expect(arm.isEnabled == false)
        #expect(arm.name == "Busy copy")

        try service.removeArm(armID: id)
        #expect(try service.snapshot().arms.isEmpty)
    }
}
#endif
