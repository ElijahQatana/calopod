import CalopodDomain
import CalopodStore
import Foundation

extension ArmFilters {
    /// False when a filter leaves this event out.
    func copies(_ event: StoredNormalizedInstance) -> Bool {
        if skipDeclined && event.currentUserResponse.state == .declined { return false }
        if skipAllDay && event.isAllDay { return false }
        if skipDontClone && hasDontCloneTag(title: event.title, notes: event.notes) { return false }
        return true
    }
}

// Kept apart so the shared tag reader can replace it.
private func hasDontCloneTag(title: String?, notes: String?) -> Bool {
    [title, notes].contains { $0?.localizedCaseInsensitiveContains("#dontclone") == true }
}
