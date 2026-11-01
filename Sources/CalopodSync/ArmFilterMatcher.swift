import CalopodDomain
import CalopodStore
import Foundation

extension ArmFilters {
    /// False when a filter or the kind of event leaves it out.
    func copies(_ event: StoredNormalizedInstance) -> Bool {
        leftOutReason(event) == nil
    }

    func leftOutReason(_ event: StoredNormalizedInstance) -> SyncPlanReason? {
        switch event.kind {
        case .workingLocation: return .workingLocation
        case .birthday: return .birthday
        case nil: break
        }
        if skipDeclined && event.currentUserResponse.state == .declined { return .filteredOut }
        if skipAllDay && event.isAllDay { return .filteredOut }
        if skipDontClone && EventTag.read(event).contains(.dontClone) { return .taggedDontClone }
        if skipFree && event.availability == "free" { return .markedFree }
        return nil
    }
}
