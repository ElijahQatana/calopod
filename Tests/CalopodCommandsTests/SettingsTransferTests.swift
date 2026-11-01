@testable import CalopodCommands
import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Settings export and import")
struct SettingsTransferTests {
    @Test("The file has no ids from this Mac")
    func exportContents() throws {
        let mac = try makeMac(prefix: "old", configured: true)
        _ = try mac.currentDevice(configurationID: "default")
        _ = try mac.iPhoneFeedZone()
        let text = String(decoding: try SettingsFile(repository: mac).encoded(), as: UTF8.self)
        let device = try mac.currentDevice(configurationID: "default").id
        let zone = try mac.iPhoneFeedZone().macID
        for secret in ["old-google", "old-work", "old-personal", "provider-old-work", device, zone] {
            #expect(!text.contains(secret))
        }
        #expect(text.contains("\"Synthetic work\""))
    }

    @Test("A new Mac gets the same settings, and a second import has nothing to do")
    func roundTrip() throws {
        let old = try makeMac(prefix: "old", configured: true)
        let new = try makeMac(prefix: "new", configured: false)
        let file = try SettingsFile(repository: old)
        let importer = SettingsImporter(repository: new)
        let plan = try importer.plan(file)
        #expect(plan.missingConnections.isEmpty && plan.unmatched.isEmpty)
        #expect(importer.apply(plan) == SettingsImportResult(applied: plan.lines.count))
        // Arms made in the same instant have no fixed order.
        #expect(try inArmOrder(SettingsFile(repository: new)) == inArmOrder(file))
        #expect(try importer.plan(file).lines.isEmpty)
    }

    @Test("The preview writes nothing")
    func previewOnly() throws {
        let old = try makeMac(prefix: "old", configured: true)
        let new = try makeMac(prefix: "new", configured: false)
        let before = try SettingsFile(repository: new)
        let plan = try SettingsImporter(repository: new).plan(SettingsFile(repository: old))
        #expect(plan.lines.contains("Add Arm \"Synthetic busy\"") && plan.addsArms)
        #expect(try SettingsFile(repository: new) == before)
    }

    @Test("Calendars and connections that are not found are listed and left alone")
    func unmatched() throws {
        let old = try makeMac(prefix: "old", configured: true)
        let new = try makeMac(prefix: "new", configured: false, skipping: "Synthetic personal", withoutMac: true)
        let importer = SettingsImporter(repository: new)
        let plan = try importer.plan(SettingsFile(repository: old))
        #expect(plan.missingConnections == ["Calendars on this Mac"])
        #expect(plan.unmatched.contains("Calendar \"Synthetic personal\""))
        #expect(plan.unmatched.contains { $0.hasPrefix("Arm") })
        _ = importer.apply(plan)
        #expect(try new.arms().isEmpty)
        let selected = try new.connections().flatMap { try new.calendarBindings(connectionID: $0.id) }.filter(\.isSelected)
        #expect(selected.map(\.displayLabel) == ["Synthetic work"])
    }

    @Test("A calendar name found twice is not guessed")
    func ambiguous() throws {
        let old = try makeMac(prefix: "old", configured: true)
        let new = try makeMac(prefix: "new", configured: false, duplicating: "Synthetic work")
        let plan = try SettingsImporter(repository: new).plan(SettingsFile(repository: old))
        #expect(plan.unmatched.contains("Calendar \"Synthetic work\""))
    }

    @Test("Unusable files are refused", arguments: [
        ("{\"formatVersion\": 2}", SettingsFileError.newerVersion(2)),
        ("{\"formatVersion\": 99}", .newerVersion(99)),
        ("{\"formatVersion\": 0}", .unreadable),
        ("{}", .unreadable),
        ("not json", .unreadable),
        ("{\"formatVersion\": 1}", .unreadable),
    ])
    func refused(text: String, error: SettingsFileError) {
        #expect(throws: error) { try SettingsFile.decode(Data(text.utf8)) }
    }

    @Test("A setting out of range is refused before anything is written")
    func outOfRange() throws {
        let old = try makeMac(prefix: "old", configured: true)
        var file = try SettingsFile(repository: old)
        file.reminders.firstMinutes = 500
        let new = try makeMac(prefix: "new", configured: false)
        #expect(throws: SettingsFileError.unusable) { try SettingsImporter(repository: new).plan(file) }
    }

    @Test("An Arm already here is updated, not added again")
    func existingArm() throws {
        let old = try makeMac(prefix: "old", configured: true)
        let new = try makeMac(prefix: "new", configured: false)
        let importer = SettingsImporter(repository: new)
        _ = importer.apply(try importer.plan(SettingsFile(repository: old)))
        var file = try SettingsFile(repository: old)
        let index = try #require(file.arms.firstIndex { !$0.main })
        file.arms[index].padding = ArmPadding(beforeMinutes: 5, afterMinutes: 10)
        file.arms[index].enabled = false
        let plan = try importer.plan(file)
        #expect(plan.lines == ["Change Arm \"Synthetic busy\" (padding, turn off)"])
        _ = importer.apply(plan)
        let arm = try #require(try new.arm(id: file.arms[index].id))
        #expect(arm.padding.afterMinutes == 10 && !arm.isEnabled)
    }
}

private func inArmOrder(_ file: SettingsFile) -> SettingsFile {
    var file = file
    file.arms.sort { $0.id < $1.id }
    return file
}

/// A Mac with a Google connection and the calendars of this Mac. Ids start with `prefix` so the two
/// Macs differ. A configured one has choices made on every setting.
private func makeMac(
    prefix: String, configured: Bool, skipping: String? = nil, withoutMac: Bool = false,
    duplicating: String? = nil
) throws -> LocalStateRepository {
    let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
    var connections = [("\(prefix)-google", "google", "Google Calendar", ["Synthetic work", "Synthetic personal", "Synthetic spare"])]
    if !withoutMac {
        connections.append(("eventkit-device", "eventkit", "Calendars on this Mac", ["Synthetic target"]))
    }
    for (index, (id, provider, label, names)) in connections.enumerated() {
        try repository.saveConnection(StoredConnection(
            id: id, configurationID: "default", provider: provider, displayLabel: label, isEnabled: true),
            now: Date(timeIntervalSince1970: Double(index)))
        let all = names.filter { $0 != skipping } + (duplicating.map { [$0] } ?? [])
        try repository.replaceCalendarBindings(connectionID: id, bindings: all.enumerated().map { index, name in
            StoredCalendarBinding(
                id: "\(prefix)-\(name.split(separator: " ").last!)\(index)", connectionID: id,
                providerCalendarID: "provider-\(prefix)-\(index)", displayLabel: name, isSelected: false, isReadOnly: false)
        })
    }
    guard configured else { return repository }

    let all = try repository.connections().flatMap { try repository.calendarBindings(connectionID: $0.id) }
    func binding(_ name: String) -> StoredCalendarBinding { all.first { $0.displayLabel == name }! }
    let work = binding("Synthetic work"), personal = binding("Synthetic personal"), target = binding("Synthetic target")
    for calendar in [work, personal] { try repository.setCalendarSelection(id: calendar.id, isSelected: true) }
    try repository.setCalendarAlias("Home", calendarID: personal.id)
    try repository.setCalendarColor("blue", calendarID: work.id)
    try repository.setCalendarIgnored(true, calendarID: personal.id)
    try repository.setCalendarHidden(true, view: CalendarViewMode.sources.rawValue, calendarID: work.id)
    try repository.setIPhoneCalendar(personal.id, chosen: true)

    let service = ArmConfigurationService(repository: repository)
    try service.configureMainCalendar(id: "synthetic-main", sourceBindingIDs: [work.id], targetBindingID: target.id)
    try service.createArm(
        id: "synthetic-busy", sourceBindingIDs: [personal.id], targetBindingID: target.id, ruleMode: .label,
        name: "Synthetic busy", filters: ArmFilters(skipDeclined: true), label: "Personal",
        padding: ArmPadding(beforeMinutes: 10, afterMinutes: 15, inPersonOnly: true))

    try repository.saveWorkingHours(WorkingHours(days: Dictionary(uniqueKeysWithValues: (1...4).map {
        ($0, try WorkingHours.Day(startMinute: 480, endMinute: 960))
    })))
    try repository.saveFocusSettings(FocusSettings(minutes: 90))
    try repository.saveNotificationSettings(NotificationSettings(
        firstMinutes: 15, finalMinutes: 5, hideTitles: true))
    try repository.saveInboxContextSettings(InboxContextSettings(beforeMinutes: 30, afterMinutes: 45))
    try repository.saveInboxDigestSettings(InboxDigestSettings(enabled: true, minute: 495))
    return repository
}
