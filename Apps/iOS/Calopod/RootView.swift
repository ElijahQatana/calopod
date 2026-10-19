import SwiftUI

struct RootView: View {
    var store: SnapshotStore
    @Bindable var reminders: Reminders
    var now: () -> Date = { .now }
    @State private var navigation = Navigation()
    @State private var filter = CalendarFilter()
    @State private var appearance = Appearance()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            screens
            if let page = navigation.page { pageScreen(page) }
            if navigation.menuOpen {
                MenuDrawer(navigation: navigation, calendarsSummary: snapshot.map(filter.summary))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: navigation.menuOpen)
        .environment(\.openMenu, { navigation.menuOpen = true })
        .preferredColorScheme(appearance.choice.colorScheme)
        .tint(Theme.accent)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .onChange(of: reminders.requestedEvent, initial: true) { _, id in
            if id != nil { navigation.show(.calendar) }
        }
    }

    private var snapshot: Snapshot? {
        if case .content(let snapshot, _) = store.phase { snapshot } else { nil }
    }

    @ViewBuilder private func pageScreen(_ page: Navigation.Page) -> some View {
        switch page {
        case .settings:
            SettingsScreen(
                info: SettingsInfo(phase: store.phase), snapshot: snapshot, reminders: reminders, appearance: appearance,
                filter: filter, navigation: navigation)
        case .calendars: CalendarsScreen(snapshot: snapshot, filter: filter, navigation: navigation)
        case .help: HelpScreen(navigation: navigation)
        case .about: AboutScreen(navigation: navigation)
        }
    }

    private var screens: some View {
        Group {
            switch store.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.screen)
            case .sharingOff:
                EmptyState(
                    title: "Welcome", subtitle: "iPhone sync is off", heading: "Your Mac stays in charge",
                    message: "Calopod on your Mac can share your Inbox, calendar and sync status with this phone. Nothing appears here until you turn it on there.",
                    steps: ["Open Calopod on your Mac", "Go to Settings, then iPhone", "Turn on Share with iPhone"],
                    systemImage: "macbook.and.iphone")
            case .nothingPublished:
                EmptyState(
                    title: "Waiting", subtitle: "Nothing published yet", heading: "Nothing here yet",
                    message: "Sharing is on, but your Mac hasn't published anything. Open Calopod on your Mac and let it finish a sync.",
                    systemImage: "icloud")
            case .failed:
                EmptyState(
                    title: "Offline", subtitle: "Couldn't reach iCloud", heading: "Can't read your snapshot",
                    message: "Check that this phone is online and signed in to iCloud, then open the app again.",
                    systemImage: "icloud.slash")
            case .signedOut:
                EmptyState(
                    title: "iCloud", subtitle: "Not signed in", heading: "Sign in to iCloud to see your calendar",
                    message: "Calopod reads what your Mac shares through iCloud. Sign in to iCloud in Settings on this phone, then open the app again.",
                    systemImage: "person.crop.circle.badge.exclamationmark")
            case .needsNewerApp:
                EmptyState(
                    title: "Update needed", subtitle: "Your Mac is newer", heading: "Update Calopod on this phone",
                    message: "Your Mac is publishing in a format this version doesn't understand yet.",
                    systemImage: "arrow.down.app")
            case .content(let snapshot, let offline):
                let context = SnapshotContext(snapshot: snapshot, offline: offline, now: now())
                @Bindable var navigation = navigation
                TabView(selection: $navigation.tab) {
                    HomeTab(context: context, filter: filter, navigation: navigation)
                        .tabItem { Label("Home", systemImage: "house") }.tag(Navigation.Tab.home)
                    InboxTab(context: context, filter: $navigation.inboxFilter)
                        .tabItem { Label("Inbox", systemImage: "tray") }.tag(Navigation.Tab.inbox)
                    CalendarTab(context: context, filter: filter, navigation: navigation, requested: $reminders.requestedEvent)
                        .tabItem { Label("Calendar", systemImage: "calendar") }.tag(Navigation.Tab.calendar)
                    StatusTab(context: context)
                        .tabItem { Label("Status", systemImage: "waveform.path.ecg") }.tag(Navigation.Tab.status)
                }
            }
        }
    }

    /// Reads the Mac's latest snapshot, then brings the reminders in step with it.
    private func refresh() async {
        await store.refresh()
        await reminders.update(for: store.phase)
    }
}
