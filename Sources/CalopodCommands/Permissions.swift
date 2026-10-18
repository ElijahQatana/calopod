import CalopodDomain
import CalopodEventKit
import CalopodProviders
import CalopodStore
import Foundation
import Security
#if os(macOS)
import ServiceManagement
#endif

/// What the app and `calopod doctor` say about the three things Calopod needs from macOS.
public struct PermissionReading: Equatable, Sendable {
    public enum ID: String, Sendable, CaseIterable {
        case calendar, loginItems, keychain
    }

    public enum Level: String, Sendable {
        case allowed
        /// macOS has not asked yet, or there is nothing to check yet.
        case notAsked
        /// Denied, waiting for approval, or not readable.
        case blocked
        /// This copy of Calopod cannot tell.
        case unknown
    }

    public let id: ID
    public let level: Level
    /// A few words for the row, such as "Allowed".
    public let state: String
    /// What it means and how to fix it.
    public let detail: String
    /// A fixed code for scripts, as used by `calopod doctor`.
    public let reason: String

    public var title: String {
        switch id {
        case .calendar: "Calendar access"
        case .loginItems: "Background service approval"
        case .keychain: "Saved sign-ins"
        }
    }
}

/// The background service as macOS sees it. Mirrors the `SMAppService` statuses.
public enum BackgroundServiceState: Equatable, Sendable {
    /// Not running from an installed app, so macOS has nothing to say.
    case unavailable
    case notRegistered
    case requiresApproval
    case enabled
    case notFound

    public static let agentPlistName = "pro.elijahquintana.calopod.app-agent.plist"

    #if os(macOS)
    /// Reads the registration of the agent bundled in the running app.
    public static func read(plistName: String = agentPlistName) -> BackgroundServiceState {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        return switch SMAppService.agent(plistName: plistName).status {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
    #endif
}

/// How reading the saved Google and Microsoft sign-ins went.
public enum KeychainCheckOutcome: Equatable, Sendable {
    case allowed(accounts: Int)
    case noAccounts
    /// macOS wants to show its own keychain prompt before the app may read.
    case needsPrompt
    case cannotRead(reason: String)
}

public enum Permissions {
    public static let calendarPrivacyURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"

    /// Also shown on the Background sync screen.
    public static let noRecordOfThisCopy =
        "macOS has no record of this copy of the app. Background services need Calopod installed in the Applications folder and signed with a developer identity, not a debug build run from a build folder."

    public static func calendar(status: EventKitAccessStatus?, hostFailure: String? = nil) -> PermissionReading {
        func reading(_ level: PermissionReading.Level, _ state: String, _ detail: String, _ reason: String) -> PermissionReading {
            PermissionReading(id: .calendar, level: level, state: state, detail: detail, reason: reason)
        }
        let settings = "Turn it on with Full Access in System Settings, Privacy & Security, Calendars."
        switch status {
        case .fullAccess:
            return reading(.allowed, "Allowed", "Calopod can read your calendars.", "allowed")
        case .notDetermined:
            return reading(
                .notAsked, "Not asked yet",
                "macOS has not asked yet. Choose Allow in Calopod, Settings, Permissions, and macOS will ask once. Nothing is read until you say yes.",
                "not-asked")
        case .denied:
            return reading(.blocked, "Denied", "Calendar access is off for Calopod. \(settings)", "denied")
        case .restricted:
            return reading(
                .blocked, "Restricted",
                "A profile or Screen Time limit blocks Calendar access on this Mac. Ask whoever manages it, then check again.",
                "restricted")
        case .writeOnly:
            return reading(.blocked, "Write only", "Calopod only has write access to Calendar. \(settings)", "write-only")
        case .unknown:
            return reading(.blocked, "Denied", "Calendar access is off for Calopod. \(settings)", "denied")
        case nil:
            let why = hostFailure.map { " \($0)" } ?? ""
            return reading(
                .unknown, "Could not check",
                "Calopod could not ask its Calendar helper.\(why)", "unreachable")
        }
    }

    public static func backgroundService(_ state: BackgroundServiceState) -> PermissionReading {
        func reading(_ level: PermissionReading.Level, _ text: String, _ detail: String, _ reason: String) -> PermissionReading {
            PermissionReading(id: .loginItems, level: level, state: text, detail: detail, reason: reason)
        }
        switch state {
        case .enabled:
            return reading(.allowed, "Allowed", "Background sync is approved and starts when you sign in.", "allowed")
        case .requiresApproval:
            return reading(
                .blocked, "Needs approval",
                "Allow Calopod in System Settings, General, Login Items.", "needs-approval")
        case .notRegistered:
            return reading(
                .notAsked, "Not set up",
                "Background sync is not installed. Install it from Background sync in Calopod, and macOS will ask for approval if needed.",
                "not-registered")
        case .notFound:
            return reading(.blocked, "Not found", noRecordOfThisCopy, "not-found")
        case .unavailable:
            return reading(
                .unknown, "Not checked",
                "Syncing moves into the app once Calopod runs as an installed app, not from a build folder.",
                "unavailable")
        }
    }

    public static func keychain(_ outcome: KeychainCheckOutcome?) -> PermissionReading {
        func reading(_ level: PermissionReading.Level, _ state: String, _ detail: String, _ reason: String) -> PermissionReading {
            PermissionReading(id: .keychain, level: level, state: state, detail: detail, reason: reason)
        }
        switch outcome {
        case nil:
            return reading(.unknown, "Not checked", "Press Check to read the saved sign-ins. macOS may ask.", "not-checked")
        case .allowed(let accounts)?:
            return reading(
                .allowed, "Allowed",
                "Calopod can read the saved sign-in\(accounts == 1 ? "" : "s") for \(accounts) Google or Microsoft account\(accounts == 1 ? "" : "s").",
                "allowed")
        case .noAccounts?:
            return reading(
                .unknown, "No accounts connected",
                "Nothing to check until you connect a Google or Microsoft account.", "no-accounts")
        case .needsPrompt?:
            return reading(
                .notAsked, "macOS will ask",
                "macOS will ask before Calopod reads the saved sign-ins. Choose Always Allow, so the background service and the command line can read them too, then check again.",
                "needs-prompt")
        case .cannotRead(let why)?:
            return reading(
                .blocked, "Cannot read",
                "Calopod cannot read a saved sign-in: \(why) Reconnect the account in Calopod, or allow access in Keychain Access.",
                "cannot-read")
        }
    }

    /// A plain reason for a failed question to the Calendar helper.
    public static func hostFailureReason(_ error: Error) -> String {
        if let error = error as? CommandEnvironmentError {
            switch error {
            case .missingEventKitHost, .eventKitHostUntrusted:
                return "The helper is missing or failed its signature check. Reinstall Calopod from the download. A build signed differently from the installed app is not trusted."
            case .eventKitHostTimedOut:
                return "The helper took too long to answer. Try again."
            default:
                return "The helper did not answer correctly. Check that Calopod is signed and allowed in Calendar privacy settings."
            }
        }
        return "The helper did not answer correctly. Check that Calopod is signed and allowed in Calendar privacy settings."
    }
}

/// Reads one saved sign-in per connected Google or Microsoft account.
public struct KeychainAccessCheck: Sendable {
    /// Connections whose sign-ins live in the keychain, as (provider, connection id).
    public typealias Account = (provider: String, connectionID: String)

    private let accounts: @Sendable () throws -> [Account]
    private let read: @Sendable (Account, Bool) throws -> OAuthTokens?

    public init(
        accounts: @escaping @Sendable () throws -> [Account],
        read: @escaping @Sendable (Account, Bool) throws -> OAuthTokens?
    ) {
        self.accounts = accounts
        self.read = read
    }

    /// The real keychain and the local database.
    public static let live = KeychainAccessCheck(
        accounts: {
            let repository = try CommandEnvironment.repository()
            return try [ProviderKind.google, .microsoft].flatMap { kind in
                try repository.connections(provider: kind.rawValue).map { (kind.rawValue, $0.id) }
            }
        },
        read: { account, interactive in
            let store = KeychainSecretStore(allowsPrompt: interactive)
            return try OAuthTokenVault(secretStore: store)
                .tokens(provider: account.provider, connectionID: account.connectionID)
        })

    /// `interactive` false never lets macOS show its keychain prompt; a read that would need it
    /// reports `.needsPrompt` instead.
    public func run(interactive: Bool) -> KeychainCheckOutcome {
        let found: [Account]
        do { found = try accounts() } catch {
            return .cannotRead(reason: "Calopod's saved data could not be read.")
        }
        guard !found.isEmpty else { return .noAccounts }
        var failure: String?
        for account in found {
            do {
                if try read(account, interactive) == nil {
                    failure = failure ?? "no saved sign-in was found for one of your accounts."
                }
            } catch let SecretStoreError.keychainStatus(status) {
                if Self.promptStatuses.contains(status) { return .needsPrompt }
                let text = SecCopyErrorMessageString(status, nil).map { "\($0 as String)." }
                failure = failure ?? text ?? "the keychain returned error \(status)."
            } catch {
                failure = failure ?? "a saved sign-in is damaged."
            }
        }
        return failure.map { .cannotRead(reason: $0) } ?? .allowed(accounts: found.count)
    }

    /// Interaction not allowed, authorization failed and user cancelled.
    private static let promptStatuses: Set<Int32> = [-25308, -25293, -128]
}
