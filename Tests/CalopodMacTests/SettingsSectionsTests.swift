import Testing

@testable import CalopodMac

struct SettingsSectionsTests {
    private let all: Set<SettingsFeature> = [.updates, .iPhone, .commandLine]

    @Test(arguments: [
        ("", [SettingsSection.appearance, .workingHours, .notifications, .iPhone, .permissions, .app]),
        ("glass", [.appearance]),
        ("FOCUS", [.workingHours]),
        ("notifications", [.notifications, .permissions]),
        ("daily digest", [.notifications]),
        ("login items", [.permissions]),
        ("terminal install", [.app]),
        ("new mac", [.app]),
        ("nothing matches this", []),
    ])
    func sectionsMatchingQuery(query: String, expected: [SettingsSection]) {
        #expect(SettingsSection.results(query: query, features: all).map(\.section) == expected)
    }

    @Test func titleMatchKeepsEveryItem() {
        let counts = SettingsSection.results(query: "permissions", features: all).map(\.count)
        #expect(counts == [SettingsSection.permissions.items.count])
    }

    @Test func countsMatchingItems() {
        let results = SettingsSection.results(query: "notifications", features: all)
        #expect(results.map(\.count) == [SettingsSection.notifications.items.count, 1])
    }

    @Test func missingFeaturesHideTheirItems() {
        let none = SettingsSection.results(query: "", features: [])
        #expect(!none.map(\.section).contains(.iPhone))
        #expect(none.first { $0.section == .app }?.count == 3)
        #expect(SettingsSection.results(query: "icloud", features: []).isEmpty)
    }

    @Test func selectionFallsBackToTheFirstResult() {
        let results = SettingsSection.results(query: "glass", features: all)
        #expect(SettingsSection.shown(selected: .appearance, in: results) == .appearance)
        #expect(SettingsSection.shown(selected: .iPhone, in: results) == .appearance)
        #expect(SettingsSection.shown(selected: .iPhone, in: []) == nil)
    }
}
