import CalopodDomain
import CalopodStore
import Foundation

extension ArmFilters {
    /// False when a filter leaves this event out.
    func copies(_ event: StoredNormalizedInstance) -> Bool {
        if skipDeclined && event.currentUserResponse.state == .declined { return false }
        if skipAllDay && event.isAllDay { return false }
        if skipDontClone && EventTag.read(event).contains(.dontClone) { return false }
        return true
    }
}
