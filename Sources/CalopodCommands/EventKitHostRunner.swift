#if os(macOS)
import CalopodEventKit
import Foundation

struct EventKitHostRunner {
    private let appURL: URL
    private let executableURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let configured = environment["CALOPOD_EVENTKIT_HOST_APP"], !configured.isEmpty {
            appURL = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            appURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/eventkit-host/Calopod EventKit Host.app")
        }
        executableURL = appURL
            .appendingPathComponent("Contents/MacOS/CalopodEventKitHost")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CommandEnvironmentError.missingEventKitHost
        }
    }

    func requestPermission() throws -> EventKitHostResponse {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-eventkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.json")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-W", "-n",
            "--stdout", stdoutURL.path,
            "--stderr", stderrURL.path,
            appURL.path,
            "--args", "--request-permission",
        ]
        try process.run()
        process.waitUntilExit()

        let data = try Data(contentsOf: stdoutURL)
        guard let response = try? JSONDecoder().decode(EventKitHostResponse.self, from: data) else {
            throw CommandEnvironmentError.eventKitHostFailed
        }
        return response
    }

    func perform(_ request: EventKitHostRequest) throws -> EventKitHostResponse {
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        let data = try JSONEncoder().encode(request)
        input.fileHandleForWriting.write(data)
        try input.fileHandleForWriting.close()
        let responseData = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let response = try? JSONDecoder().decode(
            EventKitHostResponse.self,
            from: responseData
        ) else {
            throw CommandEnvironmentError.eventKitHostFailed
        }
        return response
    }
}
#endif
