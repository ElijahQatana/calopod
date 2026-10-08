import Foundation

enum AgentServiceConfigurationError: Error, Equatable {
    case invalidPropertyList
    case invalidLabel
    case invalidProgram
    case invalidEnvironment
    case invalidSchedule
}

struct AgentServiceConfiguration: Equatable {
    static let label = "pro.elijahquintana.calopod.agent"

    let programURL: URL
    let stateURL: URL
    let eventKitHostURL: URL
    let intervalSeconds: Int
    let jitterSeconds: Int
    let lookbackDays: Int
    let horizonDays: Int
    let environment: [String: String]

    static func load(from url: URL) throws -> AgentServiceConfiguration {
        let data = try Data(contentsOf: url)
        guard let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw AgentServiceConfigurationError.invalidPropertyList
        }
        guard propertyList["Label"] as? String == label else {
            throw AgentServiceConfigurationError.invalidLabel
        }
        guard let arguments = propertyList["ProgramArguments"] as? [String],
              let program = arguments.first,
              arguments.count == 1,
              program.hasPrefix("/") else {
            throw AgentServiceConfigurationError.invalidProgram
        }
        guard let environment = propertyList["EnvironmentVariables"] as? [String: String],
              let statePath = environment["CALOPOD_STATE_PATH"], statePath.hasPrefix("/"),
              let hostPath = environment["CALOPOD_EVENTKIT_HOST_APP"], hostPath.hasPrefix("/") else {
            throw AgentServiceConfigurationError.invalidEnvironment
        }
        guard let interval = integer(
            environment["CALOPOD_AGENT_INTERVAL_SECONDS"],
            minimum: 1
        ), let jitter = integer(
            environment["CALOPOD_AGENT_JITTER_SECONDS"],
            minimum: 0
        ), let lookback = integer(
            environment["CALOPOD_AGENT_LOOKBACK_DAYS"],
            minimum: 0
        ), let horizon = integer(
            environment["CALOPOD_AGENT_HORIZON_DAYS"],
            minimum: 1
        ) else {
            throw AgentServiceConfigurationError.invalidSchedule
        }

        return AgentServiceConfiguration(
            programURL: URL(fileURLWithPath: program).standardizedFileURL,
            stateURL: URL(fileURLWithPath: statePath).standardizedFileURL,
            eventKitHostURL: URL(fileURLWithPath: hostPath).standardizedFileURL,
            intervalSeconds: interval,
            jitterSeconds: jitter,
            lookbackDays: lookback,
            horizonDays: horizon,
            environment: environment
        )
    }

    private static func integer(_ value: String?, minimum: Int) -> Int? {
        guard let value, let result = Int(value), result >= minimum else { return nil }
        return result
    }
}
