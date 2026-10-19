@testable import CalopodStore
import Foundation
import GRDB
import Testing

@Suite("Working hours")
struct WorkingHoursTests {
    @Test("Nothing saved means Monday to Friday, 9 to 5")
    func defaults() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let hours = try repository.workingHours()
        #expect(hours == .standard)
        #expect(hours.day(isoWeekday: 3)?.startMinute == 540 && hours.day(isoWeekday: 6) == nil)
    }

    @Test("Times that do not fit one day are refused")
    func validation() {
        for (start, end) in [(600, 600), (700, 600), (-1, 600), (0, 1441)] {
            #expect(throws: WorkingHoursError.invalidTimes) { try WorkingHours.Day(startMinute: start, endMinute: end) }
        }
        #expect(throws: WorkingHoursError.invalidWeekday) { try WorkingHours(days: [0: WorkingHours.Day(startMinute: 0, endMinute: 60)]) }
    }

    @Test("Saved hours, including days off, come back after reopening")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite").path
        let saved = try WorkingHours(days: [
            2: WorkingHours.Day(startMinute: 480, endMinute: 960), 6: WorkingHours.Day(startMinute: 600, endMinute: 720),
        ])
        do {
            let repository = LocalStateRepository(database: try CalopodDatabase(path: path))
            try repository.saveWorkingHours(.standard)
            try repository.saveWorkingHours(saved)
        }
        let reopened = LocalStateRepository(database: try CalopodDatabase(path: path))
        #expect(try reopened.workingHours() == saved)
        // Every day off is a valid choice and stays distinct from nothing saved.
        try reopened.saveWorkingHours(WorkingHours(days: [:]))
        #expect(try reopened.workingHours().days.isEmpty)
    }

    @Test("Weekdays are numbered from Monday whatever the calendar's first day")
    func isoWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        let sunday = Date(timeIntervalSince1970: 1_772_928_000) // 2026-03-08
        #expect(WorkingHours.isoWeekday(of: sunday, calendar: calendar) == 7)
        #expect(WorkingHours.isoWeekday(of: sunday.addingTimeInterval(86_400), calendar: calendar) == 1)
    }

    @Test("A state from before the table gains it")
    func migration() throws {
        let queue = try DatabaseQueue()
        try CalopodDatabase.migrator.migrate(queue, upTo: "v20_notification_settings")
        #expect(try queue.read { try $0.tableExists("working_hours") } == false)
        try CalopodDatabase.migrator.migrate(queue)
        #expect(try queue.read { try $0.tableExists("working_hours") })
    }
}
