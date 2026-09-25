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
            if CommandLine.arguments.dropFirst() == ["--request-permission"] {
                let status = try await client.requestFullAccess()
                response = EventKitHostResponse(status: status)
            } else {
                let requestData = FileHandle.standardInput.readDataToEndOfFile()
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
