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
        if arguments == ["--request-permission"] {
            PermissionRequest.run()
        }
        let client = EventKitClient()
        do {
            let requestData: Data
            if arguments.count == 2, arguments[0] == "--request-file" {
                requestData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
            } else if arguments.isEmpty {
                requestData = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                throw ProviderFailure.invalidResponse
            }
            let request = try JSONDecoder().decode(EventKitHostRequest.self, from: requestData)
            let response = try await handle(request, client: client)
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
            try? write(EventKitHostResponse(status: status, errorCode: code))
            exit(77)
        } catch {
            try? write(
                EventKitHostResponse(
                    status: await client.authorizationStatus,
                    errorCode: "host-failure"
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

    static func write(_ response: EventKitHostResponse) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(response)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// The Calendar prompt needs a real app: a process that never starts NSApplication is not activated
/// and macOS has nothing to attach the prompt to. So this runs the request inside the app loop,
/// then exits once the answer has been written.
@MainActor
enum PermissionRequest {
    private static let delegate = Delegate()

    static func run() -> Never {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(70)
    }

    private static func finish(_ response: EventKitHostResponse, reason: String?, code: Int32) -> Never {
        try? EventKitHostMain.write(response)
        if let reason {
            try? FileHandle.standardError.write(contentsOf: Data("\(reason)\n".utf8))
        }
        exit(code)
    }

    @MainActor private final class Delegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            // An agent app's prompt can open behind other windows, so come forward first.
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in await ask() }
        }

        private func ask() async {
            let client = EventKitClient()
            do {
                let status = try await client.requestFullAccess()
                let outcome = CalendarAccessOutcome(statusAfterRequest: status)
                let reason: String? = switch outcome {
                case .granted: nil
                case .denied: "Calendar access was denied (\(status.rawValue))."
                case .undecided: "The request returned but macOS gave no answer, so it did not show the prompt."
                case .couldNotStart: "The Calendar request could not start."
                }
                PermissionRequest.finish(
                    EventKitHostResponse(status: status, requestOutcome: outcome), reason: reason, code: 0)
            } catch {
                let denied: Bool
                if let failure = error as? ProviderFailure, case .permissionDenied = failure { denied = true } else { denied = false }
                PermissionRequest.finish(
                    EventKitHostResponse(
                        status: await client.authorizationStatus,
                        errorCode: denied ? "permission-denied" : "host-failure",
                        requestOutcome: denied ? .denied : .couldNotStart),
                    reason: denied ? "Calendar access was denied." : "The Calendar request failed before macOS answered.",
                    code: denied ? 77 : 70)
            }
        }
    }
}
