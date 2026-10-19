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

#if os(macOS)
private func makeAppLayout(in directory: URL) throws -> (command: URL, link: URL, bundled: URL, stale: URL) {
    let fileManager = FileManager.default
    let contents = directory.appendingPathComponent("Applications/Calopod.app/Contents/MacOS", isDirectory: true)
    let bundled = contents.appendingPathComponent("eventkit-host/Calopod EventKit Host.app", isDirectory: true)
    let stale = directory
        .appendingPathComponent("Library/Application Support/Calopod/Service/eventkit-host/Calopod EventKit Host.app", isDirectory: true)
    let bin = directory.appendingPathComponent(".local/bin", isDirectory: true)
    for path in [bundled, stale, bin] {
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
    }
    let command = contents.appendingPathComponent("calopod")
    #expect(fileManager.createFile(atPath: command.path, contents: Data()))
    let link = bin.appendingPathComponent("calopod")
    try fileManager.createSymbolicLink(at: link, withDestinationURL: command)
    return (command, link, bundled, stale)
}

@Test
func aLinkedCommandUsesTheHelperInsideItsOwnApp() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-app-host-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = try makeAppLayout(in: directory)

    let resolved = try EventKitHostRunner.resolveAppURL(environment: [:], executableURL: layout.link)
    #expect(resolved.resolvingSymlinksInPath() == layout.bundled.resolvingSymlinksInPath())
    #expect(resolved.path != layout.stale.path)
}

@Test
func anAppNeverFallsBackToAHelperOutsideIt() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-app-host-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = try makeAppLayout(in: directory)
    try FileManager.default.removeItem(at: layout.bundled)
    // A source-install helper beside the app must not answer for it.
    let beside = directory.appendingPathComponent("Applications/eventkit-host/Calopod EventKit Host.app", isDirectory: true)
    try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)

    #expect(throws: CommandEnvironmentError.missingEventKitHost) {
        try EventKitHostRunner.resolveAppURL(environment: [:], executableURL: layout.link)
    }
}

@Test
func aSetPathStillWinsOverTheAppHelper() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-app-host-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = try makeAppLayout(in: directory)

    let resolved = try EventKitHostRunner.resolveAppURL(
        environment: ["CALOPOD_EVENTKIT_HOST_APP": layout.stale.path],
        executableURL: layout.link
    )
    #expect(resolved == layout.stale.standardizedFileURL)
}

@Test
func doctorNamesTheCalendarHelperItAsked() {
    let base = DoctorReport(status: "ok", message: "Automatic sync checks passed.", items: [], warnings: [])
    let readings = [Permissions.calendar(status: .notDetermined)]
    let report = withPermissions(base, readings, calendarHelper: "/Applications/Calopod.app/Contents/MacOS/eventkit-host/Calopod EventKit Host.app")
    #expect(report.items.first?.label == "/Applications/Calopod.app/Contents/MacOS/eventkit-host/Calopod EventKit Host.app")

    let text = HumanOutputRenderer.render(
        command: "doctor",
        payload: CommandPayload(status: report.status, message: report.message, count: report.items.count, items: report.items),
        warnings: report.warnings, showIDs: false, context: HumanOutputContext(), width: 200
    )
    #expect(text.contains("Helper: /Applications/Calopod.app/Contents/MacOS/eventkit-host/Calopod EventKit Host.app"))
}
#endif
