/// Aggregate ingestion categories. Expected copy exclusions are not invalid records.
public struct EventIngestionSummary: Codable, Equatable, Sendable {
    public var excludedMarkedCopyCount: Int
    public var excludedMappedCopyCount: Int
    public var invalidIdentityCount: Int
    public var invalidTimespanCount: Int
    public var outOfRangeCount: Int

    public init(
        excludedMarkedCopyCount: Int = 0,
        excludedMappedCopyCount: Int = 0,
        invalidIdentityCount: Int = 0,
        invalidTimespanCount: Int = 0,
        outOfRangeCount: Int = 0
    ) {
        self.excludedMarkedCopyCount = excludedMarkedCopyCount
        self.excludedMappedCopyCount = excludedMappedCopyCount
        self.invalidIdentityCount = invalidIdentityCount
        self.invalidTimespanCount = invalidTimespanCount
        self.outOfRangeCount = outOfRangeCount
    }

    public mutating func add(_ other: Self) {
        excludedMarkedCopyCount += other.excludedMarkedCopyCount
        excludedMappedCopyCount += other.excludedMappedCopyCount
        invalidIdentityCount += other.invalidIdentityCount
        invalidTimespanCount += other.invalidTimespanCount
        outOfRangeCount += other.outOfRangeCount
    }

    public var discardedCount: Int {
        excludedMarkedCopyCount + excludedMappedCopyCount + invalidIdentityCount
            + invalidTimespanCount + outOfRangeCount
    }

    public var warnings: [String] {
        var result: [String] = []
        if invalidIdentityCount > 0 {
            result.append("Ignored event records with invalid identity: \(invalidIdentityCount).")
        }
        if invalidTimespanCount > 0 {
            result.append("Ignored event records with invalid timespans: \(invalidTimespanCount).")
        }
        return result
    }
}

/// Informational plan evidence, never permission to apply or proof of cancellation.
public struct SyncReviewSummary: Codable, Equatable, Sendable {
    public var recurringOccurrenceCreateCount: Int
    public var legacyRecurringRemovalCandidateCount: Int
    public var otherSourceMissingRemovalCount: Int
    public var staleMappingCleanupCount: Int
    public var targetRecreationCount: Int
    public var otherRepairCount: Int

    public init(
        recurringOccurrenceCreateCount: Int = 0,
        legacyRecurringRemovalCandidateCount: Int = 0,
        otherSourceMissingRemovalCount: Int = 0,
        staleMappingCleanupCount: Int = 0,
        targetRecreationCount: Int = 0,
        otherRepairCount: Int = 0
    ) {
        self.recurringOccurrenceCreateCount = recurringOccurrenceCreateCount
        self.legacyRecurringRemovalCandidateCount = legacyRecurringRemovalCandidateCount
        self.otherSourceMissingRemovalCount = otherSourceMissingRemovalCount
        self.staleMappingCleanupCount = staleMappingCleanupCount
        self.targetRecreationCount = targetRecreationCount
        self.otherRepairCount = otherRepairCount
    }

    public mutating func add(_ other: Self) {
        recurringOccurrenceCreateCount += other.recurringOccurrenceCreateCount
        legacyRecurringRemovalCandidateCount += other.legacyRecurringRemovalCandidateCount
        otherSourceMissingRemovalCount += other.otherSourceMissingRemovalCount
        staleMappingCleanupCount += other.staleMappingCleanupCount
        targetRecreationCount += other.targetRecreationCount
        otherRepairCount += other.otherRepairCount
    }
}
