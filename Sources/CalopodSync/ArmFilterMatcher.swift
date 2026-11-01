import CalopodDomain
import CalopodStore
import Foundation

extension ArmFilters {
    /// False when a filter leaves this event out.
    func copies(_ event: StoredNormalizedInstance) -> Bool {
        leftOutReason(event) == nil
    }

    func leftOutReason(_ event: StoredNormalizedInstance) -> SyncPlanReason? {
        if skipDeclined && event.currentUserResponse.state == .declined { return .filteredOut }
        if skipAllDay && event.isAllDay { return .filteredOut }
        if skipDontClone && EventTag.read(event).contains(.dontClone) { return .taggedDontClone }
        return nil
    }
}
