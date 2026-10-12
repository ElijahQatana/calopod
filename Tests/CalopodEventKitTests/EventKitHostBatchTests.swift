import CalopodEventKit
import CalopodProviders
import Foundation
import Testing

struct EventKitHostBatchTests {
    @Test
    func failureStopsDependentDeletesAndContinuesOtherItems() async throws {
        let recorder = BatchCalls()
        let request = EventKitHostRequest(operation: .batch, protocolVersion: 2, batches: [
            [EventKitHostRequest(operation: .updateManagedEvent),
             EventKitHostRequest(operation: .deleteManagedEvent)],
            [EventKitHostRequest(operation: .createManagedEvent)]
        ])
        let response = await EventKitHostBatch.handle(request, status: .fullAccess) { item in
            await recorder.record(item.operation)
            if item.operation == .updateManagedEvent { throw ProviderFailure.httpStatus(412) }
            return EventKitHostResponse(status: .fullAccess)
        }
        #expect(response.batches?.map { $0.map(\.errorCode) } ==
                [["provider-failure", "dependency-failed"], [nil]])
        #expect(await recorder.operations == [.updateManagedEvent, .createManagedEvent])
        let decoded = try JSONDecoder().decode(EventKitHostResponse.self,
                                               from: JSONEncoder().encode(response))
        #expect(decoded.protocolVersion == 2)
        #expect(decoded.batches?.count == 2)
    }

    @Test
    func incompatibleAndNestedRequestsDoNotPerformOperations() async {
        for request in [
            EventKitHostRequest(operation: .batch, protocolVersion: 99, batches: []),
            EventKitHostRequest(operation: .batch, protocolVersion: 2,
                                batches: [[EventKitHostRequest(operation: .batch)]])
        ] {
            let response = await EventKitHostBatch.handle(request, status: .fullAccess) { _ in
                Issue.record("Unexpected operation")
                return EventKitHostResponse(status: .fullAccess)
            }
            #expect(response.errorCode == "host-protocol-version")
        }
    }
}

private actor BatchCalls {
    private(set) var operations: [EventKitHostOperation] = []
    func record(_ operation: EventKitHostOperation) { operations.append(operation) }
}
