import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands

@Suite("Arm sync status")
struct ArmSyncStatusTests {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private static let fiveMinutesAgo = now.addingTimeInterval(-300)

    private static func status(enabled: Bool = true, _ health: StoredArmSyncHealth?) -> ArmSyncStatus {
        ArmSyncStatus(
            arm: StoredArm(
                id: "synthetic-arm", configurationID: "synthetic-configuration",
                sourceBindingIDs: ["synthetic-source"], targetBindingID: "synthetic-target",
                ruleMode: .busy, isEnabled: enabled),
            health: health)
    }

    private static func health(success: Date? = nil, error: String? = nil, waiting: Int? = nil) -> StoredArmSyncHealth {
        StoredArmSyncHealth(armID: "synthetic-arm", lastSuccessAt: success, lastError: error, waiting: waiting)
    }

    @Test("Each state says what it is", arguments: [
        (true, health(success: fiveMinutesAgo, waiting: 0), ArmSyncStatus.State.ok, "Synced 5 minutes ago, nothing waiting"),
        (true, health(success: fiveMinutesAgo, waiting: 3), .ok, "Synced 5 minutes ago, 3 changes waiting"),
        (true, health(success: fiveMinutesAgo, waiting: 1), .ok, "Synced 5 minutes ago, 1 change waiting"),
        (true, health(success: fiveMinutesAgo, error: "target-refresh"), .failing,
         "Last synced 5 minutes ago, last error: could not read the target calendars"),
        (true, health(error: "authorization"), .failing,
         "Never synced successfully, last error: a calendar account needs to be reconnected"),
        (true, nil, .neverSynced, "Not synced yet"),
        (true, health(waiting: 2), .neverSynced, "Not synced yet"),
        (false, health(success: fiveMinutesAgo, waiting: 0), .disabled, "Disabled"),
        (false, nil, .disabled, "Disabled"),
    ] as [(Bool, StoredArmSyncHealth?, ArmSyncStatus.State, String)])
    func line(enabled: Bool, stored: StoredArmSyncHealth?, state: ArmSyncStatus.State, text: String) {
        let status = Self.status(enabled: enabled, stored)
        #expect(status.state == state)
        #expect(status.line(now: Self.now) == text)
    }

    @Test("An error outside Calopod's own categories shows as a provider error")
    func unknownError() {
        let status = Self.status(Self.health(success: Self.fiveMinutesAgo, error: "Synthetic Calendar said no"))
        #expect(status.errorCategory == "provider")
        #expect(!status.line(now: Self.now).contains("Synthetic"))
    }

    @Test("Doctor reports every Arm without its name or any provider text")
    func doctorChecks() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        try repository.saveConnection(StoredConnection(
            id: "synthetic-connection", configurationID: "synthetic-configuration",
            provider: "eventkit", displayLabel: "Synthetic provider", isEnabled: true))
        try repository.replaceCalendarBindings(
            connectionID: "synthetic-connection",
            bindings: ["synthetic-source", "synthetic-target"].map {
                StoredCalendarBinding(
                    id: $0, connectionID: "synthetic-connection", providerCalendarID: "provider-\($0)",
                    displayLabel: $0, isSelected: true, isReadOnly: false)
            })
        let arms = ["healthy", "failing", "new", "off"]
        for name in arms {
            try repository.saveArm(StoredArm(
                id: name, configurationID: "synthetic-configuration", sourceBindingIDs: ["synthetic-source"],
                targetBindingID: "synthetic-target", ruleMode: .busy, isEnabled: name != "off",
                name: "Synthetic \(name) name"))
        }
        let at = Date().addingTimeInterval(-300)
        try repository.recordArmSync(armID: "healthy", succeededAt: at, error: nil, waiting: 2)
        try repository.recordArmSync(armID: "failing", succeededAt: at, error: "Synthetic provider text", waiting: nil)

        let checks = try armSyncChecks(repository: repository)
        #expect(checks.items.map(\.kind).sorted() == ["attention", "ok", "pending", "skipped"])
        #expect(checks.items.map(\.syncState).sorted { ($0 ?? "") < ($1 ?? "") } == ["disabled", "failing", "never-synced", "ok"])
        let text = (checks.items.compactMap(\.label) + checks.items.compactMap(\.reason) + checks.warnings).joined(separator: " ")
        #expect(!text.contains("Synthetic"))
        #expect(text.contains("2 changes waiting"))
    }
}
