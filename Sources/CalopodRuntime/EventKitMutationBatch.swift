#if os(macOS)
import CalopodEventKit
import CalopodProviders
import CalopodSync

extension EventKitHostRunner {
    func performMutations(
        _ batches: [[ManagedEventMutation]],
        calendarID: String
    ) async throws -> [[Result<ManagedEventMutationResult, ProviderFailure>]] {
        let requests = batches.map { batch in
            batch.map { mutation in
                switch mutation {
                case let .create(request):
                    EventKitHostRequest(operation: .createManagedEvent,
                                        calendarIDs: [calendarID], managedEvent: request)
                case let .update(id, version, request):
                    EventKitHostRequest(operation: .updateManagedEvent,
                                        calendarIDs: [calendarID], managedEvent: request,
                                        providerEventID: id, expectedProviderVersion: version)
                case let .delete(id, version):
                    EventKitHostRequest(operation: .deleteManagedEvent,
                                        calendarIDs: [calendarID], providerEventID: id,
                                        expectedProviderVersion: version)
                }
            }
        }
        let response = try await perform(EventKitHostRequest(
            operation: .batch, protocolVersion: EventKitHostBatch.protocolVersion, batches: requests
        ))
        guard response.protocolVersion == EventKitHostBatch.protocolVersion else {
            throw CalopodRuntimeError.eventKitHostVersionMismatch
        }
        guard response.errorCode == nil,
              let replies = response.batches, replies.count == batches.count,
              zip(replies, batches).allSatisfy({ $0.count == $1.count }) else {
            throw ProviderFailure.invalidResponse
        }
        return zip(replies, batches).map { replies, mutations in
            zip(replies, mutations).map { reply, mutation in
                guard reply.status == .fullAccess, reply.errorCode == nil else {
                    return .failure(.invalidResponse)
                }
                switch mutation {
                case .create, .update:
                    guard let result = reply.managedEvent else { return .failure(.invalidResponse) }
                    return .success(.written(result))
                case .delete:
                    return .success(.deleted)
                }
            }
        }
    }
}
#endif
