import Foundation
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

/// Every place that shows a calendar name asks the alias lookup. The checks run a fixture alias
/// through the code paths and then read the sources for a raw provider name slipping in.
@MainActor
final class CalendarNameCallSitesTests: XCTestCase {
    private func aliases() -> CalendarAliases {
        let aliases = CalendarAliases(defaults: UserDefaults(suiteName: "names-\(UUID().uuidString)")!, state: nil)
        aliases.setAlias("Office", for: "a", real: "Work")
        return aliases
    }

    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func stale() -> CalendarSchedule {
        CalendarSchedule(calendars: [ScheduleCalendar(id: "a", name: "Work", account: "Example", provider: "google", freshness: .unread)], events: [])
    }

    func testWarningsAndAttentionRowsUseTheAlias() {
        let aliases = aliases()
        let name = { (calendar: ScheduleCalendar) in aliases.name(for: calendar.id, real: calendar.name) }
        XCTAssertEqual(UpNext.staleToday(in: stale(), now: day, name: name), ["Office"])
        let notices = ScheduleLayout.notices(
            calendars: stale().calendars, hidden: [], range: day..<day.addingTimeInterval(86_400), now: day, name: name)
        XCTAssertTrue(notices.allSatisfy { $0.hasPrefix("Office ") }, "\(notices)")
    }

    func testPickersAndSetupListsUseTheAlias() {
        let aliases = aliases()
        let connection = SetupConnection(
            id: "c", provider: "google", label: "Example", isEnabled: true,
            calendars: [SetupCalendar(id: "a", name: "Work", sourceLabel: nil, isSelected: true, isReadOnly: false, providerColor: nil)],
            warnings: [])
        XCTAssertEqual(NewArmDraft.groups(from: [connection], aliases: aliases).first?.calendars.map(\.name), ["Office"])
        XCTAssertEqual(aliases.name(for: connection.calendars[0]), "Office")
    }

    /// A name read straight from the provider fields must go through the lookup on the same line.
    /// The files listed show something that is already the shown name, or edit the name itself.
    func testNoViewReadsARawProviderName() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CalopodMac")
        let alreadyShown: Set<String> = ["CalendarRow.swift", "NewArmSheet.swift"]
        let raw = try NSRegularExpression(pattern: #"\.(calendarName|sourceCalendarName)\b|\bcalendar\.name\b"#)
        var offenders: [String] = []
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" && !alreadyShown.contains(file.lastPathComponent) {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard raw.firstMatch(in: line, range: range) != nil else { continue }
                if line.contains("name(for") || line.contains("real:") { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
