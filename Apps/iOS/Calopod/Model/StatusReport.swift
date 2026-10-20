import CalopodSnapshot
import Foundation

/// What the Status screen says, taken from the sync status and the calendar list.
struct StatusReport: Equatable {
    struct Row: Equatable {
        var calendar: CalendarEntry
        var issue: SyncIssue?
        /// When the Mac last looked at this calendar. Nil from an older Mac.
        var updatedAt: Date?
    }

    /// The most runs the history bar draws.
    static let barCount = 24

    var lastSyncAt: Date?
    var issues: [SyncIssue]
    var rows: [Row]
    /// The most recent runs, oldest first. Nil from an older Mac, which gets no history bar.
    var runs: [SyncRunMark]?

    init(status: SyncStatus, calendars: [CalendarEntry]) {
        lastSyncAt = status.lastSyncAt
        issues = status.issues
        runs = status.runs.map { Array($0.suffix(Self.barCount)) }
        rows = calendars.map { calendar in
            Row(
                calendar: calendar, issue: status.issues.first { $0.calendarID == calendar.id },
                updatedAt: status.calendarUpdates?.first { $0.calendarID == calendar.id }?.at)
        }
    }

    var failedRuns: Int { runs?.filter(\.failed).count ?? 0 }

    var hasFailure: Bool { issues.contains { $0.kind == .failed } }

    func message(for issue: SyncIssue) -> String {
        let name = issue.calendarID.flatMap { id in rows.first { $0.calendar.id == id }?.calendar.name }
        switch issue.kind {
        case .failed: return name.map { "\($0) failed to sync." } ?? "The last sync failed."
        case .partial: return name.map { "\($0) only partly synced." } ?? "The last sync was only partial."
        case .stale: return name.map { "\($0) hasn't refreshed in a while." } ?? "Calendars haven't refreshed in a while."
        }
    }
}

extension SyncIssueKind {
    var label: String {
        switch self {
        case .failed: "Failed"
        case .partial: "Partial"
        case .stale: "Behind"
        }
    }
}
