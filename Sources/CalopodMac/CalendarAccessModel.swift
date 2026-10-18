import AppKit
import CalopodCommands
import CalopodEventKit
import Foundation
import Observation

/// What the app should say about Calendar access, worked out from what the helper app reports
/// and how the last sync ended.
enum CalendarAccessState: Equatable {
    /// Not asked about yet, or the helper could not be reached.
    case unchecked
    case granted
    /// macOS has not asked yet, so the app can trigger the prompt.
    case canAsk
    /// Denied, restricted or read-only. macOS will not ask again.
    case blocked

    /// `lastSyncFailure` is the failure category of the last background sync, if it failed.
    static func resolve(status: EventKitAccessStatus?, lastSyncFailure: String?) -> Self {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .canAsk
        case .denied, .restricted, .writeOnly, .unknown: .blocked
        case nil: lastSyncFailure == "permission" ? .blocked : .unchecked
        }
    }

    var isMissing: Bool { self == .canAsk || self == .blocked }

    var title: String {
        self == .canAsk ? "Calopod needs Calendar access" : "Calopod cannot read your calendars"
    }

    var message: String {
        switch self {
        case .canAsk:
            "Allow access and macOS will ask once. Nothing is read until you say yes."
        case .blocked:
            "Calendar access is off for Calopod EventKit Host. Turn it on with Full Access in System Settings, under Privacy & Security, Calendars."
        case .unchecked, .granted:
            ""
        }
    }
}

/// Asks the helper app for its Calendar access, at launch and whenever the app comes forward.
@MainActor
@Observable
final class CalendarAccessModel {
    static let privacyPage = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    private(set) var status: EventKitAccessStatus?
    private(set) var asking = false
    private var checking = false

    @ObservationIgnored private let readStatus: @Sendable () throws -> EventKitAccessStatus
    @ObservationIgnored private let requestAccess: @Sendable () throws -> EventKitAccessStatus
    @ObservationIgnored private let open: (URL) -> Void

    init(
        readStatus: @escaping @Sendable () throws -> EventKitAccessStatus = { try CalendarAccessService().status() },
        requestAccess: @escaping @Sendable () throws -> EventKitAccessStatus = { try CalendarAccessService().request() },
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.readStatus = readStatus
        self.requestAccess = requestAccess
        self.open = open
    }

    func state(lastSyncFailure: String?) -> CalendarAccessState {
        .resolve(status: status, lastSyncFailure: lastSyncFailure)
    }

    /// Asks the helper for its status. A helper that cannot be reached leaves the last answer alone.
    func check() async {
        guard !checking, !asking else { return }
        checking = true
        defer { checking = false }
        let read = readStatus
        if let found = try? await Task.detached(operation: { try read() }).value, found != status {
            status = found
        }
    }

    /// Lets the helper trigger the macOS prompt, then keeps whatever it reports afterwards.
    func allow() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        let request = requestAccess
        if let found = try? await Task.detached(operation: { try request() }).value {
            status = found
        }
    }

    func openPrivacySettings() { open(Self.privacyPage) }
}
