import CalopodDomain
import CalopodStore
import Foundation
import Testing

@Test
func mirrorMappingsPersistProviderState() throws {
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
                id: "source",
                connectionID: connection.id,
                providerCalendarID: "provider-source",
                displayLabel: "Synthetic source",
                isSelected: true,
                isReadOnly: false
            ),
            StoredCalendarBinding(
                id: "target",
                connectionID: connection.id,
                providerCalendarID: "provider-target",
                displayLabel: "Synthetic target",
                isSelected: false,
                isReadOnly: false
            ),
        ]
    )
    try repository.saveArm(
        StoredArm(
            id: "arm",
            configurationID: connection.configurationID,
            sourceBindingIDs: ["source"],
            targetBindingID: "target",
            ruleMode: .busy
        )
    )
    let initial = StoredMirrorMapping(
        mirrorKey: "mirror",
        armID: "arm",
        sourceKeyHash: "source-key",
        providerEventID: "provider-event",
        providerVersion: "v1",
        desiredFingerprint: "first",
        ownershipKeyID: "synthetic-key",
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let updated = StoredMirrorMapping(
        mirrorKey: initial.mirrorKey,
        armID: initial.armID,
        sourceKeyHash: initial.sourceKeyHash,
        providerEventID: initial.providerEventID,
        providerVersion: "v2",
        desiredFingerprint: "second",
        ownershipKeyID: initial.ownershipKeyID,
        updatedAt: Date(timeIntervalSince1970: 2)
    )

    try repository.saveMirrorMapping(initial)
    try repository.saveMirrorMapping(updated)

    #expect(try repository.mirrorMappings(armID: "arm") == [updated])
}
