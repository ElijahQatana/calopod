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
        let text = String(decoding: try SettingsFile(repository: mac).encoded(), as: UTF8.self)
        let device = try mac.currentDevice(configurationID: "default").id
        let zone = try mac.iPhoneFeedZone().macID
        for secret in ["old-google", "old-work", "old-personal", "provider-old-work", device, zone] {
            #expect(!text.contains(secret))
        }
        #expect(text.contains("\"Synthetic work\""))
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
    for (id, provider, label, names) in connections {
        try repository.saveConnection(StoredConnection(
            id: id, configurationID: "default", provider: provider, displayLabel: label, isEnabled: true))
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
