import CalopodDomain

public actor SyncEngine {
    public init() {}

    public func run(_ request: SyncRequest) async throws -> SyncSummary {
        SyncSummary(
            mode: request.mode,
            window: request.window,
            plannedOperationCount: 0,
            appliedOperationCount: 0
        )
    }
}
