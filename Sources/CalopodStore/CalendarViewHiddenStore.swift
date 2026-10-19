import GRDB

/// Which calendars are hidden in each Calendar view, shared by the app and the command line. Only
/// this Mac's display changes; nothing is sent to the provider.
extension LocalStateRepository {
    public func hiddenCalendars(view: String) throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT calendar_id FROM calendar_view_hidden WHERE view = ?", arguments: [view]))
        }
    }

    public func setCalendarHidden(_ hidden: Bool, view: String, calendarID: String) throws {
        try database.write { db in
            if hidden {
                try db.execute(sql: "INSERT OR IGNORE INTO calendar_view_hidden (view, calendar_id) VALUES (?, ?)",
                               arguments: [view, calendarID])
            } else {
                try db.execute(sql: "DELETE FROM calendar_view_hidden WHERE view = ? AND calendar_id = ?",
                               arguments: [view, calendarID])
            }
        }
    }
}
