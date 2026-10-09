import CalopodDomain
import CalopodStore

/// Counts evidence already available to planning without changing its decisions.
public enum SyncPlanReview {
    public static func summarize(
        plan: SyncPlan, sources: [StoredNormalizedInstance],
        sourceProviders: [String: String]
    ) -> SyncReviewSummary {
        var occurrences = Set<String>()
        var legacyIdentities = Set<String>()
        for source in sources {
            guard sourceProviders[source.calendarBindingID] == "eventkit",
                  source.recurrenceID != nil, !source.isCancelled,
                  source.endsAt > plan.window.start, source.startsAt < plan.window.end else { continue }
            let legacy = EventNormalizer.sourceKeyHash(
                provider: "eventkit", connectionID: source.connectionID,
                calendarBindingID: source.calendarBindingID, eventID: source.providerEventID
            )
            guard source.sourceKeyHash != legacy else { continue }
            occurrences.insert(source.sourceKeyHash)
            legacyIdentities.insert(legacy)
        }
        var result = SyncReviewSummary()
        for item in plan.items {
            switch (item.action, item.reason) {
            case (.create, _):
                if let source = item.sourceKeyHash, occurrences.contains(source) {
                    result.recurringOccurrenceCreateCount += 1
                }
            case (.remove, .sourceMissing):
                if let source = item.sourceKeyHash, legacyIdentities.contains(source) {
                    result.legacyRecurringRemovalCandidateCount += 1
                } else {
                    result.otherSourceMissingRemovalCount += 1
                }
            case (.repair, .targetMissing):
                if item.payload == nil { result.staleMappingCleanupCount += 1 }
                else { result.targetRecreationCount += 1 }
            case (.repair, _): result.otherRepairCount += 1
            default: break
            }
        }
        return result
    }
}
