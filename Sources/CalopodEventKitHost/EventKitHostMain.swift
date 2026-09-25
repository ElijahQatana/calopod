import CalopodEventKit
import CalopodProviders
import Foundation

@main
@MainActor
struct EventKitHostMain {
    static func main() async {
        let client = EventKitClient()
        do {
            let response: EventKitHostResponse
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--request-permission"] {
                let status = try await client.requestFullAccess()
                response = EventKitHostResponse(status: status)
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
                response = try handle(request, client: client)
            }
            try write(response)
            exit(response.errorCode == nil ? 0 : 77)
        } catch let error as ProviderFailure {
            let status = client.authorizationStatus
            let code: String
            switch error {
            case .permissionDenied:
                code = "permission-denied"
            default:
                code = "provider-failure"
            }
            try? write(EventKitHostResponse(status: status, errorCode: code))
            exit(77)
        } catch {
            try? write(
                EventKitHostResponse(
                    status: client.authorizationStatus,
                    errorCode: "host-failure"
                )
            )
            exit(70)
        }
    }

    private static func handle(
        _ request: EventKitHostRequest,
        client: EventKitClient
    ) throws -> EventKitHostResponse {
        switch request.operation {
        case .permissionStatus:
            return EventKitHostResponse(status: client.authorizationStatus)
        case .calendars:
            return EventKitHostResponse(
                status: client.authorizationStatus,
                calendars: try client.calendars()
            )
        case .events:
            guard let start = request.start, let end = request.end else {
                throw ProviderFailure.invalidResponse
            }
            return EventKitHostResponse(
                status: client.authorizationStatus,
                events: try client.events(
                    calendarIDs: request.calendarIDs,
                    from: start,
                    through: end
                )
            )
        case .createManagedEvent:
            guard request.calendarIDs.count == 1, let managed = request.managedEvent else {
                throw ProviderFailure.invalidResponse
            }
            return EventKitHostResponse(
                status: client.authorizationStatus,
                managedEvent: try client.createManagedEvent(
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
                status: client.authorizationStatus,
                managedEvent: try client.updateManagedEvent(
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
            try client.deleteManagedEvent(
                calendarID: request.calendarIDs[0],
                providerEventID: providerEventID,
                expectedVersion: request.expectedProviderVersion
            )
            return EventKitHostResponse(status: client.authorizationStatus)
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
