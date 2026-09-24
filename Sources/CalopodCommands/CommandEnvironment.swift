import ArgumentParser
import CalopodGoogle
import CalopodProviders
import CalopodStore
import Foundation

enum CommandEnvironment {
    static func repository() throws -> LocalStateRepository {
        let environment = ProcessInfo.processInfo.environment
        let path: String
        if let override = environment["CALOPOD_STATE_PATH"], !override.isEmpty {
            path = override
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let directory = base.appendingPathComponent("Calopod", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            path = directory.appendingPathComponent("state.sqlite").path
        }
        return LocalStateRepository(database: try CalopodDatabase(path: path))
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
}

enum CommandEnvironmentError: Error, CustomStringConvertible {
    case missingGoogleClientID
    case unsupportedPlatform

    var description: String {
        switch self {
        case .missingGoogleClientID:
            "Set CALOPOD_GOOGLE_CLIENT_ID to the desktop OAuth client ID, then try again."
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

private func commandFailure(_ error: Error) -> (message: String, exitCode: CalopodExitCode) {
    if let provider = error as? ProviderFailure {
        switch provider {
        case .authorizationRequired:
            return ("Authorization is required. Reconnect the Google account.", .permissionDenied)
        case let .configurationMissing(name):
            return ("Missing configuration: \(name).", .invalidConfiguration)
        case .consentDenied:
            return ("Authorization was cancelled.", .permissionDenied)
        case .cursorExpired:
            return (
                "Google expired the saved cursor. Run the command again for a clean refresh.",
                .temporaryFailure
            )
        case let .httpStatus(status):
            return ("Google Calendar returned HTTP \(status).", .unavailable)
        case .invalidResponse:
            return ("Google Calendar returned an invalid response.", .unavailable)
        case .refreshRejected:
            return (
                "Google rejected the saved refresh token. Reconnect the account.",
                .permissionDenied
            )
        case let .temporaryFailure(retryAfter):
            let suffix = retryAfter.map { " Try again in \($0) seconds." } ?? " Try again shortly."
            return ("Google Calendar is temporarily unavailable.\(suffix)", .temporaryFailure)
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

func selectedGoogleConnection(
    id: String?,
    repository: LocalStateRepository
) throws -> StoredConnection {
    if let id {
        guard let stored = try repository.connection(id: id), stored.provider == "google" else {
            throw ValidationError("Google Connection '\(id)' was not found.")
        }
        return stored
    }
    let connections = try repository.connections(provider: "google")
    guard connections.count == 1, let only = connections.first else {
        throw ValidationError("Pass --connection with a Google Connection identifier.")
    }
    return only
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
        return binding
    }
    let selected = try repository.calendarBindings(connectionID: connectionID).filter(\.isSelected)
    guard selected.count == 1, let only = selected.first else {
        throw ValidationError("Pass --calendar with a calendar identifier.")
    }
    return only
}
