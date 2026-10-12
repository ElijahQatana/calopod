import Foundation

public enum EventKitHostBatch {
    public static let protocolVersion = 2

    // A failed operation blocks the rest of its group, but not other groups.
    public static func handle(
        _ request: EventKitHostRequest,
        status: EventKitAccessStatus,
        perform: @Sendable (EventKitHostRequest) async throws -> EventKitHostResponse
    ) async -> EventKitHostResponse {
        guard request.operation == .batch, request.protocolVersion == protocolVersion,
              let batches = request.batches,
              batches.allSatisfy({ $0.allSatisfy { $0.operation != .batch } }) else {
            return EventKitHostResponse(status: status, protocolVersion: protocolVersion,
                                        errorCode: "host-protocol-version")
        }
        var results: [[EventKitHostResponse]] = []
        for batch in batches {
            var responses: [EventKitHostResponse] = []
            var failed = false
            for item in batch {
                let response: EventKitHostResponse
                if failed {
                    response = EventKitHostResponse(status: status, errorCode: "dependency-failed")
                } else {
                    do {
                        response = try await perform(item)
                    } catch {
                        response = EventKitHostResponse(status: status, errorCode: "provider-failure")
                    }
                }
                failed = failed || response.errorCode != nil || response.status != .fullAccess
                responses.append(response)
            }
            results.append(responses)
        }
        return EventKitHostResponse(status: status, protocolVersion: protocolVersion, batches: results)
    }
}
