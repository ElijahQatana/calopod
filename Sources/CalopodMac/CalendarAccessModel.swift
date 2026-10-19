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
            "Calendar access is off for Calopod. Turn it on with Full Access in System Settings, under Privacy & Security, Calendars. \(Permissions.calendarListing)"
        case .unchecked, .granted:
            ""
        }
    }
}

/// What to tell the person after they pressed Allow. The message is never empty.
struct CalendarAccessResult: Equatable {
    let message: String
    /// Undecided or denied: show Calendar privacy settings and the reset button.
    let offersWaysForward: Bool

    static func after(_ outcome: CalendarAccessOutcome, failure: String? = nil) -> Self {
        switch outcome {
        case .granted:
            Self(message: "Calendar access is allowed.", offersWaysForward: false)
        case .denied:
            Self(message: "Calendar access was denied. Turn it on in System Settings, or reset Calopod's Calendar decision so macOS asks again. \(Permissions.calendarListing)", offersWaysForward: true)
        case .undecided:
            Self(message: "macOS did not show the prompt. Open Calendar privacy settings, or reset Calopod's Calendar decision so macOS asks again. \(Permissions.calendarListing)", offersWaysForward: true)
        case .couldNotStart:
            Self(message: failure ?? "Calopod could not start its Calendar helper.", offersWaysForward: false)
        }
    }

    static let resetFailed = Self(
        message: "Calopod could not reset its Calendar decision. You can run this in Terminal instead: \(Permissions.calendarResetCommand)",
        offersWaysForward: true)
}

/// Asks the helper app for its Calendar access, at launch and whenever the app comes forward.
@MainActor
@Observable
final class CalendarAccessModel {
    static let privacyPage = URL(string: Permissions.calendarPrivacyURL)!

    private(set) var status: EventKitAccessStatus?
    private(set) var asking = false
    /// The last answer to Allow, kept until access is seen as allowed.
    private(set) var result: CalendarAccessResult?
    /// The reset button was pressed and the person has not yet confirmed it.
    private(set) var confirmingReset = false
    /// Why the helper could not be asked, in plain words. Cleared by the next answer.
    private(set) var hostFailure: String?
    /// The helper app that answered, so the card can name it.
    private(set) var helperPath: String?
    private var checking = false

    @ObservationIgnored private let readStatus: @Sendable () throws -> EventKitAccessStatus
    @ObservationIgnored private let requestAccess: @Sendable () throws -> CalendarAccessAnswer
    @ObservationIgnored private let readHelper: @Sendable () -> String?
    @ObservationIgnored private let resetDecision: @Sendable () throws -> Void
    @ObservationIgnored private let open: (URL) -> Void

    init(
        readStatus: @escaping @Sendable () throws -> EventKitAccessStatus = { try CalendarAccessService().status() },
        requestAccess: @escaping @Sendable () throws -> CalendarAccessAnswer = { try CalendarAccessService().request() },
        readHelper: @escaping @Sendable () -> String? = { try? CalendarAccessService().hostURL().path },
        resetDecision: @escaping @Sendable () throws -> Void = { try CalendarDecisionReset().reset() },
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.readStatus = readStatus
        self.requestAccess = requestAccess
        self.readHelper = readHelper
        self.resetDecision = resetDecision
        self.open = open
    }

    /// The same words the command line and `calopod doctor` use, once the helper has answered.
    func guidance(home: String = NSHomeDirectory()) -> CalendarAccessGuidance? {
        guard let helperPath, let status, status != .fullAccess else { return nil }
        return CalendarAccessGuidance(helperPath: helperPath, status: status, home: home)
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
        let readPath = readHelper
        do {
            let found = try await Task.detached(operation: { try read() }).value
            helperPath = await Task.detached { readPath() }.value
            if found != status { status = found }
            if found == .fullAccess { result = nil }
            hostFailure = nil
        } catch {
            hostFailure = Permissions.hostFailureReason(error)
        }
    }

    /// What the busy line says while macOS is being asked.
    static let askingText = "Waiting for macOS. Answer the Calendar prompt if it appears."

    /// Lets the helper trigger the macOS prompt, then keeps whatever it reports afterwards.
    func allow() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        await ask()
    }

    func askToReset() { confirmingReset = true }
    func cancelReset() { confirmingReset = false }

    /// Clears Calopod's own Calendar decision after the person confirmed, then asks again.
    func confirmReset() async {
        guard !asking else { return }
        confirmingReset = false
        asking = true
        defer { asking = false }
        let reset = resetDecision
        do {
            try await Task.detached(operation: { try reset() }).value
        } catch {
            result = .resetFailed
            return
        }
        await ask()
    }

    private func ask() async {
        result = nil
        let request = requestAccess
        do {
            let answer = try await Task.detached(operation: { try request() }).value
            status = answer.status
            helperPath = await Task.detached { [readHelper] in readHelper() }.value
            hostFailure = nil
            result = .after(answer.outcome)
        } catch {
            let reason = Permissions.hostFailureReason(error)
            hostFailure = reason
            result = .after(.couldNotStart, failure: reason)
        }
    }

    func openPrivacySettings() { open(Self.privacyPage) }
}
