@testable import CalopodCommands
import Foundation
import Testing

#if os(macOS)
@Test
func commandEventKitHostResolutionSupportsPackagedAndDevelopmentLayouts() throws {
    #expect(throws: CommandEnvironmentError.invalidEventKitHostPath) {
        try EventKitHostRunner.resolveAppURL(
            environment: ["CALOPOD_EVENTKIT_HOST_APP": "relative/host.app"],
            executableURL: URL(fileURLWithPath: "/tmp/calopod")
        )
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-command-host-path-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let packagedHost = directory
        .appendingPathComponent("Service/eventkit-host", isDirectory: true)
        .appendingPathComponent("Calopod EventKit Host.app", isDirectory: true)
    try FileManager.default.createDirectory(at: packagedHost, withIntermediateDirectories: true)
    let packagedExecutable = directory
        .appendingPathComponent("Service/bin", isDirectory: true)
        .appendingPathComponent("calopod")
    try FileManager.default.createDirectory(
        at: packagedExecutable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: packagedExecutable.path, contents: Data()))
    let linkDirectory = directory.appendingPathComponent("links", isDirectory: true)
    try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
    let linkedExecutable = linkDirectory.appendingPathComponent("calopod")
    try FileManager.default.createSymbolicLink(
        at: linkedExecutable,
        withDestinationURL: packagedExecutable
    )

    let packaged = try EventKitHostRunner.resolveAppURL(
        environment: [:],
        executableURL: linkedExecutable
    )
    #expect(packaged == packagedHost.standardizedFileURL)

    try FileManager.default.removeItem(at: packagedHost)
    let developmentHost = directory
        .appendingPathComponent(".build/eventkit-host", isDirectory: true)
        .appendingPathComponent("Calopod EventKit Host.app", isDirectory: true)
    try FileManager.default.createDirectory(at: developmentHost, withIntermediateDirectories: true)
    let developmentExecutable = directory
        .appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true)
        .appendingPathComponent("calopod")

    let development = try EventKitHostRunner.resolveAppURL(
        environment: [:],
        executableURL: developmentExecutable
    )
    #expect(development == developmentHost.standardizedFileURL)
}
#endif
