#if os(macOS)
import CalopodEventKit
import Foundation

/// What a request for Calendar access left behind: the status afterwards and how it ended.
public struct CalendarAccessAnswer: Equatable, Sendable {
    public let status: EventKitAccessStatus
    public let outcome: CalendarAccessOutcome

    public init(status: EventKitAccessStatus, outcome: CalendarAccessOutcome) {
        self.status = status
        self.outcome = outcome
    }

    /// Reads the helper's reply. A reply with an error and no outcome means the helper could not ask.
    public init(response: EventKitHostResponse) {
        status = response.status
        outcome = response.requestOutcome
            ?? (response.errorCode == nil ? CalendarAccessOutcome(statusAfterRequest: response.status) : .couldNotStart)
    }
}

/// Asks the EventKit host app about Calendar access. The host is the process macOS lists in
/// Privacy settings, so the status and the prompt both have to come from it.
public struct CalendarAccessService: Sendable {
    public init() {}

    /// The helper app this process would ask.
    public func hostURL() throws -> URL {
        try EventKitHostRunner().hostURL
    }

    public func status() throws -> EventKitAccessStatus {
        try EventKitHostRunner().perform(EventKitHostRequest(operation: .permissionStatus)).status
    }

    /// Shows the macOS prompt only while the status is undecided; the host skips it otherwise.
    public func request() throws -> CalendarAccessAnswer {
        CalendarAccessAnswer(response: try EventKitHostRunner().requestPermission())
    }
}

/// Clears macOS's Calendar decision for the Calopod helper only, so macOS asks again. It runs the
/// per-user `tccutil` command and needs no admin rights.
public struct CalendarDecisionReset: Sendable {
    public struct Failed: Error, Equatable {}

    public static let executablePath = "/usr/bin/tccutil"
    public static let arguments = ["reset", "Calendar", Permissions.calendarHelperBundleID]

    /// Starts the command and returns its exit status.
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String]) throws -> Int32

    private let runner: Runner

    public init(runner: @escaping Runner = Self.runProcess) { self.runner = runner }

    public func reset() throws {
        guard try runner(Self.executablePath, Self.arguments) == 0 else { throw Failed() }
    }

    public static func runProcess(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
#endif
