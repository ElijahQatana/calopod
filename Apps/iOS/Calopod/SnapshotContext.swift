import CalopodSnapshot
import SwiftUI

let timeFormat = Date.FormatStyle.dateTime.hour().minute()
let dayFormat = Date.FormatStyle.dateTime.weekday(.wide).day().month(.abbreviated)

/// What every tab needs: the snapshot, whether it is old, and the clock.
struct SnapshotContext {
    var snapshot: Snapshot
    var offline: Bool
    var now: Date

    var isStale: Bool { offline || Age.isStale(snapshot.publishedAt, now: now) }
    var fromMac: String { "from your Mac at \(snapshot.publishedAt.formatted(timeFormat))" }
}
