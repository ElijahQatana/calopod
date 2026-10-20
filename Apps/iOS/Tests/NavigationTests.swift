import CalopodDomain
import CalopodSnapshot
import Foundation
import Testing

@testable import Calopod

@MainActor
struct NavigationTests {
    @Test func startsOnHome() {
        #expect(Navigation().tab == .home)
    }

    @Test func aHomeTileOpensTheInboxOnItsFilter() {
        let navigation = Navigation()
        navigation.openInbox(.conflicts)
        #expect(navigation.tab == .inbox && navigation.inboxFilter == .conflicts && navigation.page == nil)
    }

    @Test func menuScreensStackAndGoBack() {
        let navigation = Navigation()
        navigation.menuOpen = true
        navigation.open(.settings)
        #expect(!navigation.menuOpen && navigation.page == .settings)
        navigation.push(.calendars)
        #expect(navigation.page == .calendars)
        navigation.back()
        #expect(navigation.page == .settings)
        navigation.back()
        #expect(navigation.page == nil)
        navigation.back()
        #expect(navigation.page == nil)
    }

    @Test func waysIntoCalendarPickTheRightSide() {
        let navigation = Navigation()
        navigation.openAvailability()
        #expect(navigation.tab == .calendar && navigation.calendarMode == .availability)
        navigation.show(.home)
        navigation.openSchedule()
        #expect(navigation.tab == .calendar && navigation.calendarMode == .schedule && navigation.calendarDay == nil)
        navigation.openAvailability()
        navigation.show(.home)
        navigation.show(.calendar)
        #expect(navigation.calendarMode == .availability, "the Calendar tab keeps the side it was left on")
    }

    @Test func openingATabLeavesTheMenuScreens() {
        let navigation = Navigation()
        navigation.open(.help)
        navigation.show(.calendar)
        #expect(navigation.tab == .calendar && navigation.page == nil)
    }
}

@MainActor
struct SettingsTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    @Test func appearanceIsKeptOnThePhone() {
        let store = defaults()
        let appearance = Appearance(defaults: store)
        #expect(appearance.choice == .system && appearance.choice.colorScheme == nil)
        appearance.choice = .dark
        #expect(Appearance(defaults: store).choice == .dark)
        #expect(Appearance.Choice.light.colorScheme == .light && Appearance.Choice.dark.colorScheme == .dark)
    }

    @Test func remindersSwitchIsKeptOnThePhone() {
        let store = defaults()
        let reminders = Reminders(center: nil, defaults: store)
        #expect(reminders.isOn)
        reminders.isOn = false
        #expect(!Reminders(center: nil, defaults: store).isOn)
    }

    @Test func hiddenCalendarsAreKeptAndCounted() {
        let store = defaults()
        let snapshot = Snapshot(
            publishedAt: .now, inbox: [], availability: [],
            days: [CalendarDay(day: "2027-01-01", timeZoneIdentifier: "UTC", events: ["a", "b", "c"].map {
                CalendarEvent(id: $0, calendarID: $0, title: $0, startsAt: .now, endsAt: .now, response: .accepted)
            })],
            calendars: ["a", "b", "c", "unused"].map { CalendarEntry(id: $0, name: $0, colorIndex: 0) }, status: SyncStatus(lastSyncAt: nil))
        let filter = CalendarFilter(defaults: store)
        #expect(filter.summary(in: snapshot) == "3 of 3 shown")
        filter.setShown(false, for: "b")
        #expect(CalendarFilter(defaults: store).summary(in: snapshot) == "2 of 3 shown")
    }

    @Test func icloudStateFollowsTheLastRead() {
        #expect(SettingsInfo(phase: .signedOut).icloud == .signedOut)
        #expect(SettingsInfo(phase: .failed).icloud == .unreachable)
        #expect(SettingsInfo(phase: .nothingPublished).icloud == .signedIn)
        #expect(SettingsInfo(phase: .nothingPublished).lastUpdate == nil)
    }

    @Test func macReminderChoicesAreShownAsText() {
        func info(_ settings: ReminderSettings?) -> SettingsInfo {
            SettingsInfo(phase: .content(Snapshot(publishedAt: .now, inbox: [], availability: [], reminders: settings, calendars: [], status: SyncStatus(lastSyncAt: nil)), offline: false))
        }
        let both = info(ReminderSettings(enabled: true, firstEnabled: true, firstMinutes: 10, finalEnabled: true, finalMinutes: 1, hideTitles: true))
        #expect(both.leadTimes == "10 min and 1 min before" && both.titles == "Hidden")
        #expect(info(ReminderSettings(enabled: false, firstEnabled: true, firstMinutes: 10, finalEnabled: false, finalMinutes: 1, hideTitles: false)).leadTimes == "Off")
        #expect(info(nil).leadTimes == "Not shared yet")
    }

    @Test func versionComesFromTheBundle() {
        #expect(AppInfo.version(["CFBundleShortVersionString": "1.2", "CFBundleVersion": "42"]) == "1.2 (42)")
        #expect(AppInfo.version([:]) == "1.0")
    }
}
