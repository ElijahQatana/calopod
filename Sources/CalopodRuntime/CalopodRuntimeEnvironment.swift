import CalopodGoogle
import CalopodMicrosoft
import CalopodProviders
import CalopodStore
import Foundation

public enum CalopodRuntimeError: Error, Equatable, Sendable {
    case invalidStatePath
    case invalidEventKitHostPath
    case missingEventKitHost
    case eventKitHostFailed
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

public struct CalopodStateLocation: Equatable, Sendable {
    public let databaseURL: URL
    private let protectsExistingDirectory: Bool

    public var lockURL: URL {
        databaseURL.appendingPathExtension("lock")
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportURL: URL? = nil
    ) throws {
        if let override = environment["CALOPOD_STATE_PATH"], !override.isEmpty {
            guard override.hasPrefix("/") else {
                throw CalopodRuntimeError.invalidStatePath
            }
            databaseURL = URL(fileURLWithPath: override).standardizedFileURL
            protectsExistingDirectory = false
        } else {
            let base = applicationSupportURL
                ?? FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first!
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
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if protectsExistingDirectory || !existed {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }

    public func prepareDatabaseFile(fileManager: FileManager = .default) throws {
        try prepareDirectory(fileManager: fileManager)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: databaseURL.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw CalopodRuntimeError.invalidStatePath
            }
        } else {
            guard fileManager.createFile(atPath: databaseURL.path, contents: nil) else {
                throw CalopodRuntimeError.invalidStatePath
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
    }
}

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
                configuration: GoogleOAuthConfiguration(clientID: clientID)
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
