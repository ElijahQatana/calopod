#if os(macOS)
import CalopodEventKit
import Foundation

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
    public func request() throws -> EventKitAccessStatus {
        try EventKitHostRunner().requestPermission().status
    }
}
#endif
