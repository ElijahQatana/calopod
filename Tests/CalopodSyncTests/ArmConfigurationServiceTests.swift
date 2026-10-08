import CalopodDomain
import CalopodStore
@testable import CalopodSync
import Foundation
import Testing

@Suite("Arm configuration")
struct ArmConfigurationServiceTests {
    @Test("Creates a Busy Arm from selected sources by default")
    func createsBusyArm() throws {
        let setup = try armTestSetup()
        let arm = try setup.service.createArm(
            id: "arm-one",
            sourceBindingIDs: ["source-two", "source-one"],
            targetBindingID: "target",
            now: Date(timeIntervalSince1970: 10)
        )

        #expect(arm.ruleMode == .busy)
        #expect(arm.sourceBindingIDs == ["source-one", "source-two"])
        #expect(arm.isEnabled)
        #expect(arm.preferredWriterDeviceID != nil)
        #expect(try setup.repository.arm(id: arm.id) == arm)
    }

    @Test("Keeps an explicit Full details Rule")
    func createsFullDetailsArm() throws {
        let setup = try armTestSetup()
        let arm = try setup.service.createArm(
            id: "arm-one",
            sourceBindingIDs: ["source-one"],
            targetBindingID: "target",
            ruleMode: .fullDetails
        )

        #expect(arm.ruleMode == .fullDetails)
    }

    @Test("Configures one Main calendar with a fixed Full details Rule")
    func configuresMainCalendar() throws {
        let setup = try armTestSetup()
        let main = try setup.service.configureMainCalendar(
            id: "main-arm",
            sourceBindingIDs: ["source-two", "source-one"],
            targetBindingID: "target"
        )

        #expect(main.isMain)
        #expect(main.ruleMode == .fullDetails)
        #expect(main.sourceBindingIDs == ["source-one", "source-two"])
        #expect(try setup.repository.arm(id: main.id) == main)
        #expect(throws: ArmConfigurationError.mainCalendarAlreadyConfigured) {
            try setup.service.configureMainCalendar(
                id: "another-main",
                sourceBindingIDs: ["source-one"],
                targetBindingID: "source-two"
            )
        }
        #expect(throws: ArmConfigurationError.mainCalendarRuleFixed) {
            try setup.service.updateRule(armID: main.id, ruleMode: .busy)
        }
    }

    @Test("Changes an existing Rule without replacing the Arm")
    func updatesRule() throws {
        let setup = try armTestSetup()
        let arm = try setup.service.createArm(
            id: "arm-one",
            sourceBindingIDs: ["source-one"],
            targetBindingID: "target"
        )

        let updated = try setup.service.updateRule(
            armID: arm.id,
            ruleMode: .fullDetails,
            now: Date(timeIntervalSince1970: 20)
        )

        #expect(updated.id == arm.id)
        #expect(updated.ruleMode == .fullDetails)
        #expect(try setup.repository.arm(id: arm.id) == updated)
    }

    @Test("An EventKit Arm can explicitly select the current preferred writer")
    func preferredWriter() throws {
        let setup = try armTestSetup()
        let legacy = StoredArm(
            id: "legacy-arm",
            configurationID: "synthetic-configuration",
            sourceBindingIDs: ["source-one"],
            targetBindingID: "target",
            ruleMode: .busy
        )
        try setup.repository.saveArm(legacy)

        let updated = try setup.service.preferCurrentDevice(armID: legacy.id)
        let current = try setup.repository.currentDevice(
            configurationID: legacy.configurationID
        )

        #expect(updated.preferredWriterDeviceID == current.id)
        #expect(try setup.repository.arm(id: legacy.id) == updated)
    }

    @Test("Only the preferred device may apply to an EventKit target")
    func writerPolicy() {
        let eventKitArm = StoredArm(
            id: "synthetic-arm",
            configurationID: "synthetic-configuration",
            sourceBindingIDs: ["source"],
            targetBindingID: "target",
            ruleMode: .busy,
            preferredWriterDeviceID: "preferred-device"
        )

        #expect(ArmWriterPolicy.allowsApply(
            arm: eventKitArm,
            targetProvider: .eventKit,
            currentDeviceID: "preferred-device"
        ))
        #expect(!ArmWriterPolicy.allowsApply(
            arm: eventKitArm,
            targetProvider: .eventKit,
            currentDeviceID: "other-device"
        ))
        #expect(ArmWriterPolicy.allowsApply(
            arm: eventKitArm,
            targetProvider: .google,
            currentDeviceID: "other-device"
        ))
    }

    @Test("Rejects an unselected source")
    func rejectsUnselectedSource() throws {
        let setup = try armTestSetup(sourceOneSelected: false)

        #expect(throws: ArmConfigurationError.sourceNotSelected("source-one")) {
            try setup.service.createArm(
                sourceBindingIDs: ["source-one"],
                targetBindingID: "target"
            )
        }
    }

    @Test("Rejects a read-only target")
    func rejectsReadOnlyTarget() throws {
        let setup = try armTestSetup(targetReadOnly: true)

        #expect(throws: ArmConfigurationError.targetReadOnly("target")) {
            try setup.service.createArm(
                sourceBindingIDs: ["source-one"],
                targetBindingID: "target"
            )
        }
    }

    @Test("Rejects duplicate routes")
    func rejectsDuplicateRoute() throws {
        let setup = try armTestSetup()
        try setup.service.createArm(
            id: "first-arm",
            sourceBindingIDs: ["source-one"],
            targetBindingID: "target"
        )

        #expect(
            throws: ArmConfigurationError.duplicateRoute(
                source: "source-one",
                target: "target"
            )
        ) {
            try setup.service.createArm(
                id: "second-arm",
                sourceBindingIDs: ["source-one"],
                targetBindingID: "target",
                ruleMode: .fullDetails
            )
        }
    }

    @Test("Allows reciprocal and three-calendar routes")
    func allowsCycle() throws {
        let setup = try armTestSetup()
        try setup.service.createArm(
            id: "first-arm",
            sourceBindingIDs: ["source-one"],
            targetBindingID: "source-two"
        )
        try setup.service.createArm(
            id: "second-arm",
            sourceBindingIDs: ["source-two"],
            targetBindingID: "target"
        )

        try setup.service.createArm(
            id: "third-arm",
            sourceBindingIDs: ["target"],
            targetBindingID: "source-one"
        )
        try setup.service.createArm(
            id: "reverse-arm",
            sourceBindingIDs: ["source-two"],
            targetBindingID: "source-one",
            ruleMode: .fullDetails
        )
        #expect(try setup.repository.arms().count == 4)
        #expect(throws: ArmConfigurationError.sourceMatchesTarget("source-one")) {
            try setup.service.createArm(
                sourceBindingIDs: ["source-one"], targetBindingID: "source-one"
            )
        }
    }

    @Test("Disabling and removing an Arm changes only its local configuration")
    func disableAndRemove() throws {
        let setup = try armTestSetup()
        let arm = try setup.service.createArm(
            id: "arm-one",
            sourceBindingIDs: ["source-one"],
            targetBindingID: "target"
        )

        let disabled = try setup.repository.setArmEnabled(id: arm.id, isEnabled: false)
        #expect(disabled?.isEnabled == false)
        #expect(try setup.repository.arms().count == 1)

        try setup.repository.removeArm(id: arm.id)
        #expect(try setup.repository.arm(id: arm.id) == nil)
    }
}

private struct ArmTestSetup {
    let repository: LocalStateRepository
    let service: ArmConfigurationService
}

private func armTestSetup(
    sourceOneSelected: Bool = true,
    targetReadOnly: Bool = false
) throws -> ArmTestSetup {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    let connection = StoredConnection(
        id: "synthetic-connection",
        configurationID: "synthetic-configuration",
        provider: "eventkit",
        displayLabel: "Synthetic provider",
        isEnabled: true
    )
    try repository.saveConnection(connection)
    try repository.replaceCalendarBindings(
        connectionID: connection.id,
        bindings: [
            StoredCalendarBinding(
                id: "source-one",
                connectionID: connection.id,
                providerCalendarID: "provider-source-one",
                displayLabel: "Synthetic source one",
                isSelected: sourceOneSelected,
                isReadOnly: false
            ),
            StoredCalendarBinding(
                id: "source-two",
                connectionID: connection.id,
                providerCalendarID: "provider-source-two",
                displayLabel: "Synthetic source two",
                isSelected: true,
                isReadOnly: false
            ),
            StoredCalendarBinding(
                id: "target",
                connectionID: connection.id,
                providerCalendarID: "provider-target",
                displayLabel: "Synthetic target",
                isSelected: true,
                isReadOnly: targetReadOnly
            ),
        ]
    )
    return ArmTestSetup(
        repository: repository,
        service: ArmConfigurationService(repository: repository)
    )
}
