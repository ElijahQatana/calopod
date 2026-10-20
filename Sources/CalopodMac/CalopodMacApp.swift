import AppKit
import CalopodCommands
import SwiftUI

@main
struct CalopodMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: CalopodAppDelegate
    @State private var service: ServiceModel
    @State private var setup = SetupModel(aliases: .shared, colors: .shared)
    @State private var inbox: InboxModel
    @State private var schedule: CalendarModel
    @State private var access: CalendarAccessModel
    @State private var permissions: PermissionsModel
    @State private var reminderSettings: NotificationSettingsModel
    @State private var workingHours: WorkingHoursModel
    @State private var availability: AvailabilityModel
    @State private var reminders: ReminderScheduler
    @State private var refresh: OverviewRefresh
    @State private var iPhoneFeed: IPhoneFeedModel
    @State private var navigation: AppNavigation
    @State private var sidebar = SidebarState()

    init() {
        let state = try? LocalState.repository()
        if let state {
            CalendarPreferenceMigration.launch(defaults: AppDefaults.standard, state: state)
        }
        let access = CalendarAccessModel()
        let service = ServiceModel(), inbox = InboxModel(), schedule = CalendarModel(aliases: .shared, state: state)
        _service = State(initialValue: service)
        _inbox = State(initialValue: inbox)
        _schedule = State(initialValue: schedule)
        _access = State(initialValue: access)
        _permissions = State(initialValue: PermissionsModel(access: access))
        let reminderSettings = NotificationSettingsModel(state: state)
        let reminders = ReminderScheduler(
            center: AppNotifications.live, settings: { reminderSettings.current() }, schedule: { schedule.schedule },
            ignored: { CalendarAliases.shared.isIgnored($0) },
            shownName: { CalendarAliases.shared.name(for: $0.id, real: $0.name) })
        reminderSettings.onChange = { Task { await reminders.reconcile() } }
        schedule.onReload = { Task { await reminders.reconcile() } }
        let workingHours = WorkingHoursModel(state: state), availability = AvailabilityModel()
        workingHours.onChange = { Task { await availability.reload() } }
        _workingHours = State(initialValue: workingHours)
        _availability = State(initialValue: availability)
        _reminderSettings = State(initialValue: reminderSettings)
        _reminders = State(initialValue: reminders)
        _refresh = State(initialValue: OverviewRefresh(inbox: inbox, schedule: schedule, service: service, access: access))
        let iPhoneFeed = IPhoneFeedModel()
        _iPhoneFeed = State(initialValue: iPhoneFeed)
        let navigation = AppNavigation()
        _navigation = State(initialValue: navigation)
        BackgroundRefresh.start(
            inbox: inbox, schedule: schedule, iPhoneFeed: iPhoneFeed, permissions: permissions, reminders: reminders,
            navigation: navigation)
        DockPresence.enter()
        AppConfiguration.apply()
        AppSettings.shared.applyAppearance()
    }

    /// One answer for Overview, the sidebar dot and the menu bar window.
    private func refreshAccess() {
        service.calendarAccess = setup.hasMacConnection
            ? access.state(lastSyncFailure: service.status?.failureCategory) : .unchecked
    }

    /// Hiding the item from Settings or by dragging it out of the menu bar both land here.
    private var menuBarItemShown: Binding<Bool> {
        Binding(
            get: { AppSettings.shared.showsMenuBarItem },
            set: { shown in
                AppSettings.shared.setShowsMenuBarItem(shown)
                if !shown { DockPresence.enter() }
            })
    }

    var body: some Scene {
        // Opens at launch and on reopen, so launching is visible.
        Window("Calopod", id: "home") {
            MainWindow(navigation: navigation, sidebar: sidebar, service: service, setup: setup, inbox: inbox)
                .environment(inbox)
                .environment(schedule)
                .environment(access)
                .environment(permissions)
                .environment(reminderSettings)
                .environment(workingHours)
                .environment(availability)
                .environment(refresh)
                .environment(\.iPhoneFeed, iPhoneFeed)
                .task { await inbox.reload() }
                .task { await access.check() }
                .onChange(of: access.status, initial: true) { refreshAccess() }
                .onChange(of: setup.hasMacConnection, initial: true) { refreshAccess() }
                .onChange(of: service.status?.failureCategory, initial: true) { refreshAccess() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await access.check() }
                }
                .onChange(of: permissions.notifications) { Task { await reminders.reconcile() } }
                .dockPresence()
                .registersWindowOpener()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1140, height: 700)
        .commands {
            SettingsCommands(navigation: navigation)
            CommandGroup(replacing: .sidebar) {
                Button(sidebar.isCollapsed ? "Show Sidebar" : "Hide Sidebar") { sidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }

        MenuBarExtra(isInserted: menuBarItemShown) {
            MenuPopover(model: service, navigation: navigation, inbox: inbox, schedule: schedule)
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: SquidMark.menuBarImage(alert: service.menuBarAlert))
                if let text = UpNext.menuBarText(waiting: inbox.waiting) {
                    Text(text).monospacedDigit()
                }
            }
            .opacity(service.menuBarDimmed ? 0.5 : 1)
            .registersWindowOpener()
        }
        .menuBarExtraStyle(.window)
    }
}

/// The Settings command, with the usual Command-Comma.
struct SettingsCommands: Commands {
    let navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                navigation.selection = .settings
                DockPresence.enter()
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "home")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
