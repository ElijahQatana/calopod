import EventKit
import Foundation

private enum ProbeMode: String {
    case check = "--check"
    case request = "--request"
}

@main
private struct EventKitAccessProbe {
    static func main() async {
        guard CommandLine.arguments.count == 2,
              let mode = ProbeMode(rawValue: CommandLine.arguments[1]) else {
            fputs("Usage: CalopodEventKitProbe --request|--check\n", stderr)
            exit(64)
        }

        let store = EKEventStore()

        if mode == .request, EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            do {
                _ = try await store.requestFullAccessToEvents()
            } catch {
                fputs("EventKit access request failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        let status = EKEventStore.authorizationStatus(for: .event)
        print("authorization=\(statusName(status))")

        guard status == .fullAccess else {
            exit(3)
        }

        let calendars = store.calendars(for: .event)
        let writableCount = calendars.filter(\.allowsContentModifications).count
        print("calendar_read=pass")
        print("calendar_count=\(calendars.count)")
        print("writable_calendar_count=\(writableCount)")
    }

    private static func statusName(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not-determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .fullAccess: "full-access"
        case .writeOnly: "write-only"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }
}
