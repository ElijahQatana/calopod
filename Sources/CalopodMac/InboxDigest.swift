import CalopodCommands
import CalopodStore
import CryptoKit
import Foundation

/// The daily Inbox notification: when it fires and what it says. Counts only, never titles.
struct PlannedDigest: Equatable, Sendable {
    let fireDate: Date
    let body: String

    var fingerprint: String {
        let text = [String(Int(fireDate.timeIntervalSince1970)), body].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum InboxDigest {
    static let id = "calopod.digest"
    static let title = "Inbox"
    static let infoKey = "calopod.digest"

    /// "3 need a reply, 1 conflict", counted the way the Inbox filters count, or nil when nothing is waiting.
    static func text(_ board: InboxBoard) -> String? {
        let parts = [
            (InboxFilter.needsRSVP, "needs a reply", "need a reply"), (.maybe, "maybe", "maybe"),
            (.changed, "changed", "changed"), (.conflicts, "conflict", "conflicts"),
        ].compactMap { filter, one, many -> String? in
            let count = board.count(filter)
            return count == 0 ? nil : "\(count) \(count == 1 ? one : many)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func plan(
        board: InboxBoard?, settings: InboxDigestSettings, workingHours: WorkingHours, now: Date,
        calendar: Calendar = .current
    ) -> PlannedDigest? {
        guard settings.enabled, let board, let body = text(board) else { return nil }
        let minute = settings.minute(workingHours: workingHours)
        let time = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
        guard let fire = calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime) else { return nil }
        return PlannedDigest(fireDate: fire, body: body)
    }
}
