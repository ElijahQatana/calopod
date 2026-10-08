@testable import CalopodCommands
import Foundation
import Testing

@Test
func installedAgentConfigurationRequiresAbsoluteValidatedValues() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-agent-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let propertyListURL = directory.appendingPathComponent("agent.plist")
    let propertyList: [String: Any] = [
        "Label": "pro.elijahquintana.calopod.agent",
        "ProgramArguments": ["/example/bin/calopod-agent"],
        "EnvironmentVariables": [
            "CALOPOD_STATE_PATH": "/example/state.sqlite",
            "CALOPOD_EVENTKIT_HOST_APP": "/example/EventKit Host.app",
            "CALOPOD_AGENT_INTERVAL_SECONDS": "600",
            "CALOPOD_AGENT_JITTER_SECONDS": "30",
            "CALOPOD_AGENT_LOOKBACK_DAYS": "1",
            "CALOPOD_AGENT_HORIZON_DAYS": "30",
        ],
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: propertyList,
        format: .xml,
        options: 0
    )
    try data.write(to: propertyListURL)

    let configuration = try AgentServiceConfiguration.load(from: propertyListURL)

    #expect(configuration.programURL.path == "/example/bin/calopod-agent")
    #expect(configuration.stateURL.path == "/example/state.sqlite")
    #expect(configuration.intervalSeconds == 600)
    #expect(configuration.jitterSeconds == 30)
    #expect(configuration.lookbackDays == 1)
    #expect(configuration.horizonDays == 30)
}

@Test
func installedAgentConfigurationRejectsRelativePathsAndInvalidSchedules() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-agent-config-invalid-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let propertyListURL = directory.appendingPathComponent("agent.plist")

    try writeAgentPropertyList(
        to: propertyListURL,
        program: "relative/calopod-agent",
        interval: "600"
    )
    #expect(throws: AgentServiceConfigurationError.invalidProgram) {
        try AgentServiceConfiguration.load(from: propertyListURL)
    }

    try writeAgentPropertyList(
        to: propertyListURL,
        program: "/example/bin/calopod-agent",
        interval: "0"
    )
    #expect(throws: AgentServiceConfigurationError.invalidSchedule) {
        try AgentServiceConfiguration.load(from: propertyListURL)
    }
}

private func writeAgentPropertyList(
    to url: URL,
    program: String,
    interval: String
) throws {
    let propertyList: [String: Any] = [
        "Label": "pro.elijahquintana.calopod.agent",
        "ProgramArguments": [program],
        "EnvironmentVariables": [
            "CALOPOD_STATE_PATH": "/example/state.sqlite",
            "CALOPOD_EVENTKIT_HOST_APP": "/example/EventKit Host.app",
            "CALOPOD_AGENT_INTERVAL_SECONDS": interval,
            "CALOPOD_AGENT_JITTER_SECONDS": "30",
            "CALOPOD_AGENT_LOOKBACK_DAYS": "1",
            "CALOPOD_AGENT_HORIZON_DAYS": "30",
        ],
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: propertyList,
        format: .xml,
        options: 0
    )
    try data.write(to: url)
}
