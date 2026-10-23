import CalopodGoogle
import CalopodMicrosoft
import CalopodProviders
import CalopodStore
import Foundation

public enum CalopodRuntimeError: Error, Equatable, Sendable {
    case invalidStatePath
    case invalidEventKitHostPath
    case missingEventKitHost
    case eventKitHostVersionMismatch
    case eventKitHostFailed
    case eventKitHostTimedOut
    case eventKitHostUntrusted
    case missingGoogleClientID
    case missingMicrosoftClientID
    case unsupportedPlatform
    case busy
    case noEnabledArms
    case invalidConfiguration(String)
    case sourceRefreshFailed
    case targetRefreshFailed
    case writerNotPreferred
    case ambiguousRepair
    case convergenceFailed
}

/// Resolves where the SQLite state and lock live and keeps their permissions owner-only. A
/// LaunchAgent has no shell environment, so the CLI and agent must derive the same path.
public struct CalopodStateLocation: Equatable, Sendable {
    public let databaseURL: URL
    private let protectsExistingDirectory: Bool

    public var lockURL: URL {
        databaseURL.appendingPathExtension("lock")
    }

    /// Interval chosen in the Mac app. A file, not a table, so older builds still open the database.
    public var scheduleOverrideURL: URL {
        databaseURL.appendingPathExtension("schedule.json")
    }

    public var accessLockURL: URL {
        databaseURL.appendingPathExtension("access.lock")
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportURL: URL? = nil
    ) throws {
        // An override must be absolute; a relative path would depend on the working directory,
        // which a LaunchAgent can't rely on.
        if let override = environment["CALOPOD_STATE_PATH"], !override.isEmpty {
            guard override.hasPrefix("/") else {
                throw CalopodRuntimeError.invalidStatePath
            }
            databaseURL = URL(fileURLWithPath: override).standardizedFileURL
            protectsExistingDirectory = false
        } else {
            if applicationSupportURL == nil { RunningUnderTests.refuseRealState() }
            guard let base = applicationSupportURL
                ?? FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                throw CalopodRuntimeError.invalidStatePath
            }
            databaseURL = base
                .appendingPathComponent("Calopod", isDirectory: true)
                .appendingPathComponent("state.sqlite")
                .standardizedFileURL
            protectsExistingDirectory = true
        }
    }

    public func prepareDirectory(fileManager: FileManager = .default) throws {
        let directory = databaseURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        let existed = fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        if existed, !isDirectory.boolValue {
            throw CalopodRuntimeError.invalidStatePath
        }
        let created = try PrivateFiles.createDirectory(at: directory)
        // The default location is always locked down. With an override, only a directory we just
        // created is tightened, never an existing one.
        if protectsExistingDirectory, !created {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }

    // Always owner-only: this file is the operational ledger.
    public func prepareDatabaseFile(fileManager: FileManager = .default) throws {
        try prepareDirectory(fileManager: fileManager)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: databaseURL.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw CalopodRuntimeError.invalidStatePath
            }
        } else {
            try PrivateFiles.createFile(at: databaseURL)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
    }
}

/// What a CLI or agent process needs to build its repository and services, without relying on shell
/// exports or the working directory.
public struct CalopodRuntimeEnvironment: Sendable {
    public let variables: [String: String]
    public let stateLocation: CalopodStateLocation
    public let executableURL: URL

    public init(
        variables: [String: String] = ProcessInfo.processInfo.environment,
        stateLocation: CalopodStateLocation? = nil,
        executableURL: URL? = Bundle.main.executableURL
    ) throws {
        self.variables = variables
        self.stateLocation = try stateLocation ?? CalopodStateLocation(environment: variables)
        guard let executableURL else {
            throw CalopodRuntimeError.invalidConfiguration("executable-path")
        }
        self.executableURL = executableURL.standardizedFileURL
    }

    public func repository() throws -> LocalStateRepository {
        try stateLocation.prepareDatabaseFile()
        let repository = LocalStateRepository(
            database: try CalopodDatabase(path: stateLocation.databaseURL.path)
        )
        return repository
    }

    public func readOnlyState() throws -> CalopodStateRead {
        let lock = try ProcessLock.acquire(at: stateLocation.accessLockURL, shared: true)
        let database = try CalopodDatabase(path: stateLocation.databaseURL.path, readonly: true)
        return CalopodStateRead(repository: LocalStateRepository(database: database), lock: lock)
    }

    public func restoreState(
        from backupPath: String,
        secrets: any SecretStore = KeychainSecretStore()
    ) throws -> LocalStateBackupSummary {
        try stateLocation.prepareDirectory()
        let writerLock = try ProcessLock.acquire(at: stateLocation.lockURL)
        defer { withExtendedLifetime(writerLock) {} }
        let accessLock = try ProcessLock.acquire(at: stateLocation.accessLockURL)
        defer { withExtendedLifetime(accessLock) {} }
        return try LocalStateBackup.restore(
            from: backupPath,
            to: stateLocation.databaseURL.path,
            secrets: secrets
        )
    }

    public func googleService(
        repository: LocalStateRepository,
        requireClientID: Bool = true
    ) throws -> GoogleConnectionService {
        let clientID = variables["CALOPOD_GOOGLE_CLIENT_ID"] ?? ""
        if requireClientID, clientID.isEmpty {
            throw CalopodRuntimeError.missingGoogleClientID
        }
        return GoogleConnectionService(
            oauth: GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(
                    clientID: clientID,
                    clientSecret: variables["CALOPOD_GOOGLE_CLIENT_SECRET"]
                )
            ),
            calendarClient: GoogleCalendarClient(),
            tokenVault: OAuthTokenVault(secretStore: KeychainSecretStore()),
            state: repository
        )
    }

    public func microsoftService(
        repository: LocalStateRepository,
        requireClientID: Bool = true
    ) throws -> MicrosoftConnectionService {
        let clientID = variables["CALOPOD_MICROSOFT_CLIENT_ID"] ?? ""
        if requireClientID, clientID.isEmpty {
            throw CalopodRuntimeError.missingMicrosoftClientID
        }
        let tenant = variables["CALOPOD_MICROSOFT_TENANT"] ?? "common"
        return MicrosoftConnectionService(
            oauth: MicrosoftOAuthClient(
                configuration: MicrosoftOAuthConfiguration(clientID: clientID, tenant: tenant)
            ),
            graph: MicrosoftGraphClient(),
            tokenVault: OAuthTokenVault(secretStore: KeychainSecretStore()),
            state: repository
        )
    }
}

/// Holds the shared recovery lock until the caller finishes using local state.
public final class CalopodStateRead: @unchecked Sendable {
    public let repository: LocalStateRepository
    private let lock: ProcessLock

    init(repository: LocalStateRepository, lock: ProcessLock) {
        self.repository = repository
        self.lock = lock
    }
}
