@testable import CalopodRuntime
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
#endif
