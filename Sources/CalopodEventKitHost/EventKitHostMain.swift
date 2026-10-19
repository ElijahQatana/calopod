import AppKit
import CalopodEventKit
import CalopodProviders
import Foundation
import CoreServices

/// Entry point for the signed EventKit host app. macOS grants Calendar access per process, so this
/// runs apart from the CLI and agent.
/// It writes one JSON object to stdout and exits 0 on success, 77 for an operation failure, or 70
/// for an unexpected one.
@main
@MainActor
struct EventKitHostMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--register-app"] {
            // Registration must use the final installed bundle location.
            let result = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
            guard result == noErr else {
                try? FileHandle.standardError.write(
                    contentsOf: Data("The Calopod app association could not be registered.\n".utf8)
                )
                exit(70)
            }
            exit(0)
        }
        let client = EventKitClient()
        do {
            let response: EventKitHostResponse
            if arguments == ["--request-permission"] {
                // An agent app has no window, so bring it forward or the prompt can open behind
                // other windows. The process stays alive until the answer comes back.
                NSApplication.shared.setActivationPolicy(.accessory)
                NSApplication.shared.activate(ignoringOtherApps: true)
                let status = try await client.requestFullAccess()
                response = EventKitHostResponse(
                    status: status,
                    requestOutcome: CalendarAccessOutcome(statusAfterRequest: status)
                )
            } else {
                let requestData: Data
                if arguments.count == 2, arguments[0] == "--request-file" {
                    requestData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
                } else if arguments.isEmpty {
                    requestData = FileHandle.standardInput.readDataToEndOfFile()
                } else {
                    throw ProviderFailure.invalidResponse
                }
                let request = try JSONDecoder().decode(EventKitHostRequest.self, from: requestData)
                response = try await handle(request, client: client)
            }
            try write(response)
            exit(response.errorCode == nil ? 0 : 77)
        } catch let error as ProviderFailure {
            let status = await client.authorizationStatus
            let code: String
            switch error {
            case .permissionDenied:
                code = "permission-denied"
            default:
                code = "provider-failure"
            }
            let outcome: CalendarAccessOutcome? = arguments == ["--request-permission"]
                ? (code == "permission-denied" ? .denied : .couldNotStart) : nil
            try? write(EventKitHostResponse(status: status, errorCode: code, requestOutcome: outcome))
            exit(77)
        } catch {
            try? write(
                EventKitHostResponse(
                    status: await client.authorizationStatus,
                    errorCode: "host-failure",
                    requestOutcome: arguments == ["--request-permission"] ? .couldNotStart : nil
                )
            )
            exit(70)
        }
    }

    /// Runs one request. Each case checks the fields it needs first, so a malformed request fails
    /// with `.invalidResponse`.
    private static func handle(
        _ request: EventKitHostRequest,
        client: EventKitClient
    ) async throws -> EventKitHostResponse {
        if request.operation == .batch {
            return await EventKitHostBatch.handle(
                request, status: await client.authorizationStatus
            ) { item in
                try await handle(item, client: client)
            }
        }

        switch request.operation {
        case .batch:
            throw ProviderFailure.invalidResponse
        case .permissionStatus:
            return EventKitHostResponse(status: await client.authorizationStatus)
        case .calendars:
            return EventKitHostResponse(
                status: await client.authorizationStatus,
                calendars: try await client.calendars()
            )
        case .events:
            guard let start = request.start, let end = request.end else {
                throw ProviderFailure.invalidResponse
            }
            return EventKitHostResponse(
                status: await client.authorizationStatus,
                events: try await client.events(
                    calendarIDs: request.calendarIDs,
                    from: start,
                    through: end
                )
            )
        case .managedEvents:
            guard request.calendarIDs.count == 1,
                  let start = request.start,
                  let end = request.end,
                  start < end else {
                throw ProviderFailure.invalidResponse
            }
            return EventKitHostResponse(
                status: await client.authorizationStatus,
                managedEvents: try await client.managedEvents(
                    calendarID: request.calendarIDs[0],
                    from: start,
                    through: end
                )
            )
        case .createManagedEvent:
            guard request.calendarIDs.count == 1, let managed = request.managedEvent else {
                throw ProviderFailure.invalidResponse
            }
            return EventKitHostResponse(
                status: await client.authorizationStatus,
                managedEvent: try await client.createManagedEvent(
                    calendarID: request.calendarIDs[0],
                    request: managed
                )
            )
        case .updateManagedEvent:
            guard request.calendarIDs.count == 1,
                  let providerEventID = request.providerEventID,
                  let managed = request.managedEvent else {
                throw ProviderFailure.invalidResponse
            }
            return EventKitHostResponse(
                status: await client.authorizationStatus,
                managedEvent: try await client.updateManagedEvent(
                    calendarID: request.calendarIDs[0],
                    providerEventID: providerEventID,
                    expectedVersion: request.expectedProviderVersion,
                    request: managed
                )
            )
        case .deleteManagedEvent:
            guard request.calendarIDs.count == 1,
                  let providerEventID = request.providerEventID else {
                throw ProviderFailure.invalidResponse
            }
            try await client.deleteManagedEvent(
                calendarID: request.calendarIDs[0],
                providerEventID: providerEventID,
                expectedVersion: request.expectedProviderVersion
            )
            return EventKitHostResponse(status: await client.authorizationStatus)
        }
    }

    private static func write(_ response: EventKitHostResponse) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(response)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
