@testable import CalopodRuntime
import CalopodDomain
import CalopodStore
import CalopodSync
import CalopodProviders
import CalopodEventKit
import Foundation
import Testing

#if os(macOS)
private func hostDirectories() -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(
        atPath: FileManager.default.temporaryDirectory.path
    )) ?? []
    return Set(names.filter { $0.hasPrefix("calopod-eventkit-") })
}

private func makeLauncher(_ body: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("launcher.sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

private func makeRunner(launcher: URL, standard: TimeInterval, permission: TimeInterval) -> EventKitHostRunner {
    EventKitHostRunner(
        appURL: URL(fileURLWithPath: "/nonexistent/Host.app"),
        launcherURL: launcher,
        standardLimit: standard,
        permissionLimit: permission,
        verifyHost: { _ in }
    )
}

@Suite(.serialized)
struct EventKitHostRunnerLimitTests {
    @Test(arguments: [1, 40, 200])
    func mutationCountDoesNotIncreaseHostLaunches(count: Int) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-host-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = directory.appendingPathComponent("response.json")
        let launches = directory.appendingPathComponent("launches")
        let capture = directory.appendingPathComponent("request.json")
        let replies = (0..<count).map { _ in [EventKitHostResponse(status: .fullAccess)] }
        try JSONEncoder().encode(EventKitHostResponse(
            status: .fullAccess, protocolVersion: 2, batches: replies
        )).write(to: response)
        let launcher = try makeLauncher(
            "echo launch >> '\(launches.path)'\ncp \"${10}\" '\(capture.path)'\ncp '\(response.path)' \"$4\"",
            in: directory
        )
        let runner = makeRunner(launcher: launcher, standard: 10, permission: 10)
        _ = try await runner.perform(EventKitHostRequest(operation: .managedEvents))
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let connection = StoredConnection(id: "synthetic-connection", configurationID: "synthetic-config",
                                          provider: "eventkit", displayLabel: "Synthetic", isEnabled: true)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [
            StoredCalendarBinding(id: "source", connectionID: connection.id, providerCalendarID: "source",
                                  displayLabel: "Synthetic source", isSelected: true, isReadOnly: false),
            StoredCalendarBinding(id: "target", connectionID: connection.id, providerCalendarID: "target",
                                  displayLabel: "Synthetic target", isSelected: false, isReadOnly: false)
        ])
        let arm = StoredArm(id: "synthetic-arm", configurationID: connection.configurationID,
                            sourceBindingIDs: ["source"], targetBindingID: "target", ruleMode: .busy)
        try repository.saveArm(arm)
        var items: [SyncPlanItem] = []
        var observations: [TargetEventObservation] = []
        for index in 0..<count {
            let id = "synthetic-\(index)"
            try repository.saveMirrorMapping(StoredMirrorMapping(
                mirrorKey: id, armID: arm.id, sourceKeyHash: id, providerEventID: id,
                providerVersion: "v1", desiredFingerprint: "fingerprint", ownershipKeyID: "key",
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ))
            items.append(SyncPlanItem(id: id, armID: arm.id, mirrorKey: id, sourceKeyHash: id,
                                     action: .remove, reason: .sourceMissing,
                                     desiredFingerprint: nil, payload: nil))
            observations.append(TargetEventObservation(
                calendarBindingID: "target", providerEventID: id, providerVersion: "v1",
                mirrorKey: id, contentFingerprint: "fingerprint", ownershipStatus: .verified
            ))
        }
        let summary = try await ManagedEventConvergenceService(
            repository: repository, secretStore: BatchSecretStore()
        ).converge(
            initialItems: items, arm: arm, targetProvider: .eventKit,
            initialObservations: observations,
            window: SyncWindow(start: Date(timeIntervalSince1970: 1_000),
                               end: Date(timeIntervalSince1970: 8_000)),
            readSnapshots: {
                try await runner.perform(EventKitHostRequest(operation: .managedEvents)).managedEvents
            },
            performBatch: { mutations in
                let results = try await runner.performMutations(mutations, calendarID: "synthetic-calendar")
                let request = try JSONDecoder().decode(EventKitHostRequest.self,
                                                       from: Data(contentsOf: capture))
                #expect(request.batches?.count == count)
                #expect(request.protocolVersion == 2)
                return results
            }, perform: { _ in
                Issue.record("Unexpected individual host operation")
                throw ProviderFailure.invalidResponse
            }
        )
        #expect(summary.providerWriteCount == count)
        #expect(try repository.mirrorMappings(armID: arm.id).isEmpty)
        #expect(try String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count == 3)

        try JSONEncoder().encode(EventKitHostResponse(status: .fullAccess)).write(to: response)
        await #expect(throws: CalopodRuntimeError.eventKitHostVersionMismatch) {
            try await runner.performMutations([[.delete(providerEventID: "synthetic", expectedVersion: nil)]],
                                              calendarID: "synthetic-calendar")
        }
    }

    @Test
    func partialAndMalformedRepliesRemainExplicit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-host-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = directory.appendingPathComponent("response.json")
        let runner = makeRunner(
            launcher: try makeLauncher("cp '\(response.path)' \"$4\"", in: directory),
            standard: 10, permission: 10
        )
        try JSONEncoder().encode(EventKitHostResponse(status: .fullAccess, protocolVersion: 2, batches: [
            [EventKitHostResponse(status: .fullAccess)],
            [EventKitHostResponse(status: .fullAccess, errorCode: "provider-failure")],
            [EventKitHostResponse(status: .fullAccess)]
        ])).write(to: response)
        let mutations: [[ManagedEventMutation]] = (0..<3).map {
            [.delete(providerEventID: "synthetic-\($0)", expectedVersion: "v1")]
        }
        let replies = try await runner.performMutations(mutations, calendarID: "synthetic")
        #expect(throws: ProviderFailure.invalidResponse) { try replies[1][0].get() }
        for index in [0, 2] {
            guard case .deleted = try replies[index][0].get() else {
                Issue.record("Expected confirmed deletion")
                continue
            }
        }
        try JSONEncoder().encode(EventKitHostResponse(status: .fullAccess, protocolVersion: 2,
                                                      batches: [[], [], []])).write(to: response)
        await #expect(throws: ProviderFailure.invalidResponse) {
            try await runner.performMutations(mutations, calendarID: "synthetic")
        }
    }

    @Test
    func hostCallStopsAtItsLimitAndLeavesNothingBehind() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-host-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = hostDirectories()
        let runner = makeRunner(
            launcher: try makeLauncher("sleep 60", in: directory),
            standard: 0.5,
            permission: 0.5
        )

        let started = Date()
        await #expect(throws: CalopodRuntimeError.eventKitHostTimedOut) {
            try await runner.perform(EventKitHostRequest(operation: .permissionStatus))
        }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(hostDirectories().subtracting(before).isEmpty)
    }

    @Test
    func fastHostIsUnaffectedAndPermissionRequestUsesItsOwnLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-host-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = directory.appendingPathComponent("response.json")
        try JSONEncoder().encode(EventKitHostResponse(status: .fullAccess)).write(to: response)
        let answer = "cp '\(response.path)' \"$4\""

        let fast = makeRunner(launcher: try makeLauncher(answer, in: directory), standard: 5, permission: 5)
        #expect(try await fast.perform(EventKitHostRequest(operation: .permissionStatus)).status == .fullAccess)

        // Slow enough to miss the standard limit but inside the permission limit.
        let slow = makeRunner(
            launcher: try makeLauncher("sleep 1\n\(answer)", in: directory),
            standard: 0.3,
            permission: 10
        )
        #expect(try slow.requestPermission().status == .fullAccess)
        await #expect(throws: CalopodRuntimeError.eventKitHostTimedOut) {
            try await slow.perform(EventKitHostRequest(operation: .permissionStatus))
        }
    }

    @Test
    func untrustedHostIsNeverLaunched() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-host-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let runner = EventKitHostRunner(
            appURL: URL(fileURLWithPath: "/nonexistent/Host.app"),
            launcherURL: try makeLauncher("touch '\(marker.path)'", in: directory),
            standardLimit: 5,
            permissionLimit: 5,
            verifyHost: { _ in throw EventKitHostSignatureError.unsigned }
        )
        await #expect(throws: CalopodRuntimeError.eventKitHostUntrusted) {
            try await runner.perform(EventKitHostRequest(operation: .permissionStatus))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func timeoutHasItsOwnFailureCategory() {
        #expect(syncFailureCategory(CalopodRuntimeError.eventKitHostTimedOut) == "eventkit-host-timeout")
    }
}

private struct BatchSecretStore: SecretStore {
    func save(_ value: Data, for reference: SecretReference) throws {}
    func value(for reference: SecretReference) throws -> Data? { nil }
    func removeValue(for reference: SecretReference) throws {}
}
#endif
