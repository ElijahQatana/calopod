#if os(macOS)
import CalopodDomain
import CalopodRuntime
import CalopodStore
import CalopodSync
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

    @Test("quick setup makes one full-details arm and one busy arm, and skips what exists")
    func twoArmSetup() throws {
        let (service, repository, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        try repository.replaceCalendarBindings(connectionID: "mac", bindings: [
            StoredCalendarBinding(id: "work", connectionID: "mac", providerCalendarID: "w",
                displayLabel: "Work", isSelected: false, isReadOnly: false),
            StoredCalendarBinding(id: "main", connectionID: "mac", providerCalendarID: "m",
                displayLabel: "Main", isSelected: false, isReadOnly: false),
            StoredCalendarBinding(id: "busy", connectionID: "mac", providerCalendarID: "b",
                displayLabel: "Busy", isSelected: false, isReadOnly: false),
        ])
        try service.setSelected(calendarID: "work", selected: true)

        try service.setUpTwoArms(sourceIDs: ["work"], fullDetailsTargetID: "main", busyTargetID: "busy")
        let arms = try service.snapshot().arms
        #expect(arms.count == 2)
        let full = try #require(arms.first { $0.rule == .fullDetails })
        let busy = try #require(arms.first { $0.rule == .busy })
        #expect(full.targetName == "Main" && busy.targetName == "Busy")
        #expect(full.sourceNames == ["Work"] && busy.sourceNames == ["Work"])
        // Stored as Main, like `calopod main configure`, so the CLI still recognizes it.
        #expect(full.isMain && !busy.isMain)

        try service.setUpTwoArms(sourceIDs: ["work"], fullDetailsTargetID: nil, busyTargetID: nil)
        #expect(try service.snapshot().arms.count == 2)
    }

    @Test("a second full-details arm is a plain arm and an existing Main stays listed")
    func existingMainStaysAnArm() throws {
        let (service, repository, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        try repository.replaceCalendarBindings(connectionID: "mac", bindings: [
            StoredCalendarBinding(id: "work", connectionID: "mac", providerCalendarID: "w",
                displayLabel: "Work", isSelected: false, isReadOnly: false),
            StoredCalendarBinding(id: "main", connectionID: "mac", providerCalendarID: "m",
                displayLabel: "Main", isSelected: false, isReadOnly: false),
            StoredCalendarBinding(id: "other", connectionID: "mac", providerCalendarID: "o",
                displayLabel: "Other", isSelected: false, isReadOnly: false),
        ])
        try service.setSelected(calendarID: "work", selected: true)
        try ArmConfigurationService(repository: repository)
            .configureMainCalendar(sourceBindingIDs: ["work"], targetBindingID: "main")

        try service.setUpTwoArms(sourceIDs: ["work"], fullDetailsTargetID: "other", busyTargetID: nil)
        let arms = try service.snapshot().arms
        #expect(arms.count == 2)
        #expect(arms.filter(\.isMain).count == 1)
        #expect(arms.allSatisfy { $0.rule == .fullDetails })

        let main = try #require(arms.first { $0.isMain })
        try service.setArmEnabled(armID: main.id, enabled: false)
        try service.removeArm(armID: main.id)
        #expect(try service.snapshot().arms.count == 1)
    }

    @Test("an unselected source is rejected with a plain message")
    func unselectedSourceIsRejected() throws {
        let (service, _, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        try service.setSelected(calendarID: "main", selected: true)
        #expect(throws: (any Error).self) {
            try service.setUpTwoArms(sourceIDs: ["work"], fullDetailsTargetID: "main", busyTargetID: nil)
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

    @Test("renaming trims the name and refuses empty, long and repeated names")
    func renameRules() throws {
        let (service, _, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        try service.setSelected(calendarID: "work", selected: true)
        try service.addArm(sourceIDs: ["work"], targetID: "main", rule: .busy, name: "Busy copy")
        try service.setSelected(calendarID: "main", selected: true)
        try service.addArm(sourceIDs: ["main"], targetID: "work", rule: .fullDetails, name: "Details")
        let arms = try service.snapshot().arms
        let busy = try #require(arms.first { $0.name == "Busy copy" })

        try service.renameArm(armID: busy.id, name: "  Team busy  ")
        #expect(try service.snapshot().arms.contains { $0.id == busy.id && $0.name == "Team busy" })
        // Keeping its own name, even in another case, is fine.
        try service.renameArm(armID: busy.id, name: "team BUSY")

        for bad in ["   ", "details", String(repeating: "a", count: 201), "two\nlines"] {
            #expect(throws: (any Error).self) { try service.renameArm(armID: busy.id, name: bad) }
        }
        #expect(try service.snapshot().arms.contains { $0.id == busy.id && $0.name == "team BUSY" })
    }
}
#endif

#if os(macOS)
@Suite("Mac health report")
struct HealthReportTests {
    @Test("a missing service is reported as a failed installation check")
    func notInstalled() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let controller = try LaunchAgentController(
            homeDirectory: home,
            userID: 501,
            launchctl: { _ in LaunchctlResult(exitCode: 1, output: "") }
        )

        let report = try AgentControlService.health(controller: controller)

        #expect(report.status == "failed")
        #expect(report.checks.map(\.name) == ["installation"])
        #expect(report.checks.first?.state == "failed")
        #expect(report.checks.first?.reason == "not-installed")
        #expect(report.warnings == ["Install the Calopod user service."])
    }
}
#endif
