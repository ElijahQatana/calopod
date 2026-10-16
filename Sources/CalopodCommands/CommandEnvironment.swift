import ArgumentParser
import CalopodEventKit
import CalopodGoogle
import CalopodMicrosoft
import CalopodProviders
import CalopodRuntime
import CalopodStore
import Foundation

enum CommandEnvironment {
    static func runtimeEnvironment() throws -> CalopodRuntimeEnvironment {
        try CalopodRuntimeEnvironment()
    }

    static func writerLock() throws -> ProcessLock {
        let environment = try runtimeEnvironment()
        try environment.stateLocation.prepareDirectory()
        return try ProcessLock.acquire(at: environment.stateLocation.lockURL)
    }

    static func repository() throws -> LocalStateRepository {
        try runtimeEnvironment().repository()
    }

    static func googleService(requireClientID: Bool = true) throws -> GoogleConnectionService {
        let clientID = ProcessInfo.processInfo.environment["CALOPOD_GOOGLE_CLIENT_ID"] ?? ""
        if requireClientID, clientID.isEmpty {
            throw CommandEnvironmentError.missingGoogleClientID
        }
        return GoogleConnectionService(
            oauth: GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: clientID)
            ),
            calendarClient: GoogleCalendarClient(),
            tokenVault: OAuthTokenVault(secretStore: KeychainSecretStore()),
            state: try repository()
        )
    }

    static func microsoftService(requireClientID: Bool = true) throws -> MicrosoftConnectionService {
        let environment = ProcessInfo.processInfo.environment
        let clientID = environment["CALOPOD_MICROSOFT_CLIENT_ID"] ?? ""
        if requireClientID, clientID.isEmpty {
            throw CommandEnvironmentError.missingMicrosoftClientID
        }
        let tenant = environment["CALOPOD_MICROSOFT_TENANT"] ?? "common"
        return MicrosoftConnectionService(
            oauth: MicrosoftOAuthClient(
                configuration: MicrosoftOAuthConfiguration(clientID: clientID, tenant: tenant)
            ),
            graph: MicrosoftGraphClient(),
            tokenVault: OAuthTokenVault(secretStore: KeychainSecretStore()),
            state: try repository()
        )
    }

    static func eventKitService() throws -> EventKitConnectionService {
        EventKitConnectionService(state: try repository())
    }
}

enum CommandEnvironmentError: Error, CustomStringConvertible {
    case missingGoogleClientID
    case missingMicrosoftClientID
    case invalidEventKitHostPath
    case missingEventKitHost
    case eventKitHostFailed
    case eventKitHostTimedOut
    case eventKitHostUntrusted
    case unsupportedPlatform

    var description: String {
        switch self {
        case .missingGoogleClientID:
            "Set CALOPOD_GOOGLE_CLIENT_ID to the desktop OAuth client ID, then try again."
        case .missingMicrosoftClientID:
            "Set CALOPOD_MICROSOFT_CLIENT_ID to the public client ID, then try again."
        case .invalidEventKitHostPath:
            "The EventKit host path must be absolute."
        case .missingEventKitHost:
            "The EventKit host is unavailable. Reinstall Calopod or rebuild it from source."
        case .eventKitHostFailed:
            "The EventKit host did not return a valid response. Verify its signature and Calendar access."
        case .eventKitHostTimedOut:
            "The EventKit host did not respond in time. Try again, or restart the user service."
        case .eventKitHostUntrusted:
            "The EventKit host failed its signature check. Reinstall Calopod or rebuild it from source."
        case .unsupportedPlatform:
            "Browser authorization is currently available on macOS."
        }
    }
}

func failCommand(_ error: Error) throws -> Never {
    let failure = commandFailure(error)
    if let data = "Error: \(failure.message)\n".data(using: .utf8) {
        try? FileHandle.standardError.write(contentsOf: data)
    }
    throw ExitCode(failure.exitCode.rawValue)
}

func commandFailure(_ error: Error) -> (message: String, exitCode: CalopodExitCode) {
    if error is CalopodDatabaseError {
        return ("Local state needs an upgrade. Run a writable command after sync finishes, then retry the read.", .localStateFailure)
    }
    if let control = error as? LaunchAgentControlError {
        return switch control {
        case .notInstalled:
            ("Install the user service before controlling automatic sync.", .unavailable)
        case .rootUnsupported:
            ("Run this command as the signed-in user, not root.", .permissionDenied)
        case .unavailable:
            ("The user service controller is unavailable.", .unavailable)
        case .operationFailed:
            ("The user service could not change state. Run doctor for details.", .temporaryFailure)
        }
    }
    if error is AgentServiceConfigurationError {
        return (
            "The installed user service configuration is invalid. Reinstall Calopod.",
            .invalidConfiguration
        )
    }
    if let backup = error as? LocalStateBackupError {
        return switch backup {
        case .invalidPath:
            ("Use an absolute path to a regular local file.", .invalidConfiguration)
        case .sourceMissing:
            ("Local state is not initialized yet.", .unavailable)
        case .destinationExists:
            ("The backup destination already exists.", .invalidConfiguration)
        case .backupInvalid:
            ("The local-state backup is invalid or damaged.", .localStateFailure)
        case .backupNotPrivate:
            ("The local-state backup must allow access only to its owner.", .permissionDenied)
        case .unsupportedSchema:
            ("The local-state backup was created by an unsupported version.", .invalidConfiguration)
        case .keyUnavailable:
            ("The backup key is not in this Mac's Keychain, so the backup can't be opened here.", .permissionDenied)
        case .stateBusy:
            ("Local state is still in use. Stop the service and other Calopod commands.", .temporaryFailure)
        }
    }
    if error is SupportCommandError {
        return (
            "Disable automatic sync before restoring local state.",
            .temporaryFailure
        )
    }
    if let runtime = error as? CalopodRuntimeError {
        switch runtime {
        case .busy:
            return ("Another Calopod operation is using local state.", .temporaryFailure)
        case .invalidStatePath:
            return ("The local state path must be an absolute writable path.", .invalidConfiguration)
        case .invalidEventKitHostPath:
            return ("The EventKit host path must be absolute.", .invalidConfiguration)
        case .missingEventKitHost:
            return (
                "The EventKit host is unavailable. Reinstall Calopod or rebuild it from source.",
                .invalidConfiguration
            )
        case .eventKitHostVersionMismatch:
            return ("The Calendar host version does not support batched sync. Install the matching release.", .invalidConfiguration)
        case .eventKitHostFailed:
            return (
                "The EventKit host did not return a valid response. Verify its signature and Calendar access.",
                .unavailable
            )
        case .eventKitHostTimedOut:
            return (
                "The EventKit host did not respond in time. Try again, or restart the user service.",
                .temporaryFailure
            )
        case .eventKitHostUntrusted:
            return (
                "The EventKit host failed its signature check. Reinstall Calopod or rebuild it from source.",
                .invalidConfiguration
            )
        case .missingGoogleClientID:
            return ("Set CALOPOD_GOOGLE_CLIENT_ID to the desktop OAuth client ID, then try again.", .invalidConfiguration)
        case .missingMicrosoftClientID:
            return ("Set CALOPOD_MICROSOFT_CLIENT_ID to the public client ID, then try again.", .invalidConfiguration)
        case .unsupportedPlatform:
            return ("This operation is not available on the current platform.", .unavailable)
        case .noEnabledArms, .invalidConfiguration:
            return ("The sync configuration is incomplete or no longer available.", .invalidConfiguration)
        case .sourceRefreshFailed:
            return ("Apply stopped because at least one source calendar could not refresh.", .unavailable)
        case .targetRefreshFailed:
            return ("Apply stopped because at least one target calendar could not refresh.", .unavailable)
        case .writerNotPreferred:
            return ("Apply stopped because this device is not the preferred writer for an EventKit Arm.", .invalidConfiguration)
        case .ambiguousRepair:
            return ("Apply stopped at an ambiguous repair. Inspect the dry run before retrying.", .invalidConfiguration)
        case .convergenceFailed:
            return ("Apply stopped because managed target changes did not converge after repeated reads.", .temporaryFailure)
        }
    }
    if let provider = error as? ProviderFailure {
        switch provider {
        case .accountPolicyRequired:
            return (
                "The account requires consent, an administrator, or another sign-in action.",
                .permissionDenied
            )
        case .authorizationRequired:
            return ("Authorization is required. Reconnect the calendar account.", .permissionDenied)
        case let .configurationMissing(name):
            return ("Missing configuration: \(name).", .invalidConfiguration)
        case .consentDenied:
            return ("Authorization was cancelled.", .permissionDenied)
        case .cursorExpired:
            return (
                "The provider expired the saved cursor. Run the command again for a clean refresh.",
                .temporaryFailure
            )
        case let .httpStatus(status):
            return ("The calendar provider returned HTTP \(status).", .unavailable)
        case .invalidResponse:
            return ("The calendar provider returned an invalid response.", .unavailable)
        case .permissionDenied:
            return (
                "Calendar access is denied. Grant full calendar access in System Settings, then try again.",
                .permissionDenied
            )
        case .refreshRejected:
            return (
                "The provider rejected the saved refresh token. Reconnect the account.",
                .permissionDenied
            )
        case let .temporaryFailure(retryAfter):
            let suffix = retryAfter.map { " Try again in \($0) seconds." } ?? " Try again shortly."
            return ("The calendar provider is temporarily unavailable.\(suffix)", .temporaryFailure)
        }
    }
    if let environment = error as? CommandEnvironmentError {
        return (environment.description, .invalidConfiguration)
    }
    if let validation = error as? ValidationError {
        return (validation.message, .usage)
    }
    if error is SecretStoreError {
        return ("The saved credential could not be accessed.", .permissionDenied)
    }
    return ("Local state could not be read or updated.", .localStateFailure)
}

func selectedConnection(
    id: String?,
    repository: LocalStateRepository
) throws -> StoredConnection {
    if let id {
        guard let stored = try repository.connection(id: id),
              stored.provider == "google"
                || stored.provider == "microsoft"
                || stored.provider == "eventkit" else {
            throw ValidationError("Connection '\(id)' was not found or is not supported here.")
        }
        return stored
    }
    let connections = try repository.connections().filter {
        $0.provider == "google" || $0.provider == "microsoft" || $0.provider == "eventkit"
    }
    guard connections.count == 1, let only = connections.first else {
        throw ValidationError("Pass --connection with a Connection identifier.")
    }
    return only
}

func refreshCalendars(for connection: StoredConnection) async throws -> [StoredCalendarBinding] {
    switch connection.provider {
    case "google":
        return try await CommandEnvironment.googleService().refreshCalendars(connectionID: connection.id)
    case "microsoft":
        return try await CommandEnvironment.microsoftService().refreshCalendars(connectionID: connection.id)
    case "eventkit":
        #if os(macOS)
        let response = try EventKitHostRunner().perform(EventKitHostRequest(operation: .calendars))
        guard response.status == .fullAccess, response.errorCode == nil else {
            throw ProviderFailure.permissionDenied
        }
        return try CommandEnvironment.eventKitService().refreshCalendars(
            response.calendars,
            connectionID: connection.id
        )
        #else
        throw CommandEnvironmentError.unsupportedPlatform
        #endif
    default:
        throw ValidationError("That provider does not support calendar discovery yet.")
    }
}

func readEvents(
    connection: StoredConnection,
    binding: StoredCalendarBinding,
    start: Date,
    end: Date
) async throws -> ProviderEventPage {
    switch connection.provider {
    case "google":
        return try await CommandEnvironment.googleService().events(
            connectionID: connection.id,
            binding: binding,
            from: start,
            through: end,
            useIncrementalRefresh: false
        )
    case "microsoft":
        return try await CommandEnvironment.microsoftService().events(
            connectionID: connection.id,
            binding: binding,
            from: start,
            through: end,
            useIncrementalRefresh: false
        )
    case "eventkit":
        #if os(macOS)
        let response = try EventKitHostRunner().perform(
            EventKitHostRequest(
                operation: .events,
                calendarIDs: [binding.providerCalendarID],
                start: start,
                end: end
            )
        )
        guard response.status == .fullAccess, response.errorCode == nil else {
            throw ProviderFailure.permissionDenied
        }
        return ProviderEventPage(events: response.events, nextSyncToken: nil)
        #else
        throw CommandEnvironmentError.unsupportedPlatform
        #endif
    default:
        throw ValidationError("That provider does not support event reads yet.")
    }
}

func disconnect(_ connection: StoredConnection) throws {
    switch connection.provider {
    case "google":
        try CommandEnvironment.googleService(requireClientID: false).disconnect(
            connectionID: connection.id
        )
    case "microsoft":
        try CommandEnvironment.microsoftService(requireClientID: false).disconnect(
            connectionID: connection.id
        )
    case "eventkit":
        try CommandEnvironment.eventKitService().disconnect(connectionID: connection.id)
    default:
        throw ValidationError("That provider does not support disconnect yet.")
    }
}

func selectedCalendarBinding(
    id: String?,
    connectionID: String,
    repository: LocalStateRepository
) throws -> StoredCalendarBinding {
    if let id {
        guard let binding = try repository.calendarBinding(id: id),
              binding.connectionID == connectionID else {
            throw ValidationError("Calendar '\(id)' was not found on that Connection.")
        }
        guard binding.isSelected else {
            throw ValidationError(
                "Calendar '\(id)' is not selected. Run calendars --select \(id) first."
            )
        }
        return binding
    }
    let selected = try repository.calendarBindings(connectionID: connectionID).filter(\.isSelected)
    guard selected.count == 1, let only = selected.first else {
        throw ValidationError("Pass --calendar with a calendar identifier.")
    }
    return only
}
