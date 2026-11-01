import AppKit
import CalopodCommands
import SwiftUI

/// Settings, one section at a time, with a search across them.
struct SettingsScreen: View {
    private let settings = AppSettings.shared
    let navigation: AppNavigation
    @State private var command: CommandLineModel
    @State private var query = ""
    @Environment(PermissionsModel.self) private var permissions
    @Environment(\.iPhoneFeed) private var iPhoneFeed
    @Environment(\.updates) private var updates
    @Environment(NotificationSettingsModel.self) private var reminders
    @Environment(WorkingHoursModel.self) private var workingHours

    init(navigation: AppNavigation, command: CommandLineModel = CommandLineModel()) {
        self.navigation = navigation
        _command = State(initialValue: command)
    }

    var body: some View { CardPage(title: "Settings") { sections } }

    /// The page contents, for rendering without the scroll view.
    var page: some View { CardPage(title: "Settings") { sections }.page }

    private var features: Set<SettingsFeature> {
        var features: Set<SettingsFeature> = []
        if updates != nil { features.insert(.updates) }
        if iPhoneFeed != nil { features.insert(.iPhone) }
        if command.isAvailable { features.insert(.commandLine) }
        return features
    }

    private var sections: some View {
        let results = SettingsSection.results(query: query, features: features)
        let shown = SettingsSection.shown(selected: navigation.settingsSection, in: results)
        return HStack(alignment: .top, spacing: 20) {
            sectionList(results, shown: shown)
            VStack(alignment: .leading, spacing: 16) {
                if let shown { content(of: shown) } else { Text("No matching settings").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh() }
        }
    }

    private func sectionList(_ results: [SettingsMatch], shown: SettingsSection?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search", text: $query).textFieldStyle(.roundedBorder).padding(.bottom, 8)
            ForEach(results, id: \.section) { result in
                let selected = result.section == shown
                Button { navigation.settingsSection = result.section } label: {
                    HStack(spacing: 8) {
                        Image(systemName: result.section.symbol).frame(width: 20)
                        Text(result.section.title).lineLimit(1)
                        Spacer(minLength: 0)
                        if !query.isEmpty { Text("\(result.count)").font(Theme.Fonts.tinySemibold.monospacedDigit()) }
                    }
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(selected ? Theme.onAccent : .primary)
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(Capsule().fill(selected ? Theme.accent : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(width: 200)
    }

    @ViewBuilder
    private func content(of section: SettingsSection) -> some View {
        switch section {
        case .appearance:
            appearance
            windowStyle
            transparency
        case .workingHours: WorkingHoursSection(model: workingHours)
        case .notifications:
            NotificationsSection(model: reminders, workingHours: workingHours.hours, permission: permissions.notifications)
        case .iPhone: iPhoneSection
        case .permissions: permissionsSection
        case .app:
            menuBar
            if let updates { UpdatesSection(model: updates) }
            commandLine
        }
    }

    @ViewBuilder
    private var iPhoneSection: some View {
        if let feed = iPhoneFeed {
            CardSection(
                "iPhone",
                footnote: feed.availability.isAvailable
                    ? "Sends a read-only copy of your Inbox, busy time, calendar names and the events of calendars you choose to your private iCloud after each sync. Nothing is shared with anyone else unless you invite them below, and nothing on the iPhone changes a calendar. Turning this off deletes the copy."
                    : feed.availability.unavailableMessage
            ) {
                CardRow("Show Inbox and busy time on iPhone") {
                    Toggle("", isOn: Binding(get: { feed.isOn }, set: { on in Task { await feed.setOn(on) } }))
                        .labelsHidden()
                        .disabled(!feed.availability.isAvailable || feed.isBusy)
                }
                if feed.availability.isAvailable { calendarRows(feed) }
                if feed.availability.isAvailable, feed.isOn { IPhoneShareRows(feed: feed) }
                if let problem = feed.problem {
                    CardRow {
                        VStack(alignment: .leading, spacing: 8) {
                            Banner(kind: .error, text: problem)
                            Button("Try again") { Task { await feed.retry() } }.disabled(feed.isBusy)
                        }
                    }
                } else if let published = feed.feed.publishedAt, feed.isOn {
                    CardRow {
                        Text("Last sent \(published.formatted(date: .abbreviated, time: .shortened))")
                            .font(Theme.Fonts.body).foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                await feed.tick()
                await feed.loadPeople()
            }
        }
    }

    /// One switch per calendar. Event titles of the chosen ones are stored in the user's iCloud.
    @ViewBuilder
    private func calendarRows(_ feed: IPhoneFeedModel) -> some View {
        CardRow {
            Text("Also send events from these calendars. Their titles are stored in your iCloud.")
                .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
        }
        ForEach(feed.calendars, id: \.id) { choice in
            CardRow {
                HStack(spacing: 8) {
                    Circle().fill(CalendarColors.shared.color(for: choice.id).color).frame(width: 12, height: 12)
                    Text(choice.name).lineLimit(1)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { choice.isChosen }, set: { on in Task { await feed.setCalendar(choice.id, chosen: on) } }))
                        .labelsHidden()
                        .disabled(feed.isBusy)
                        .accessibilityLabel("Send events from \(choice.name)")
                }
            }
        }
    }

    private var permissionsSection: some View {
        CardSection(
            "Permissions",
            footnote: "Opening Settings and coming back to Calopod re-check quietly. Only Check on saved sign-ins can make macOS ask."
        ) {
            permissionRow(permissions.calendar) {
                if permissions.calendar.level == .notAsked {
                    Button("Allow") { Task { await permissions.access.allow() } }
                        .disabled(permissions.access.asking)
                } else {
                    Button("Open Calendar privacy settings") { permissions.openCalendarPrivacy() }
                }
            }
            if CalendarAccessFeedback.isVisible(permissions.access, offerReset: calendarBlocked) {
                CardRow {
                    CalendarAccessFeedback(
                        access: permissions.access, offerReset: calendarBlocked,
                        showOpenSettings: permissions.calendar.level == .notAsked)
                }
            }
            permissionRow(permissions.backgroundService) {
                if permissions.loginItems == .requiresApproval {
                    Button("Open Login Items settings") { permissions.openLoginItemsSettings() }
                }
            }
            permissionRow(permissions.notificationsReading) {
                switch permissions.notifications {
                case .notDetermined?:
                    Button("Allow") { Task { await permissions.allowNotifications() } }
                        .disabled(permissions.askingNotifications)
                case .denied?:
                    Button("Open Notifications settings") { permissions.openNotificationsSettings() }
                default:
                    EmptyView()
                }
            }
            permissionRow(permissions.savedSignIns) {
                Button(permissions.keychain == .needsPrompt ? "Check again" : "Check") {
                    Task { await permissions.checkKeychain() }
                }
                .disabled(permissions.checkingKeychain)
            }
        }
    }

    private var calendarBlocked: Bool { permissions.calendar.level == .blocked }

    private func permissionRow<Action: View>(
        _ reading: PermissionReading, @ViewBuilder action: () -> Action
    ) -> some View {
        CardRow {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(reading.title).font(Theme.Fonts.bodyMedium)
                    Spacer(minLength: 12)
                    Text(reading.state).font(Theme.Fonts.body).foregroundStyle(Self.tint(reading.level))
                    action()
                }
                if reading.level != .allowed {
                    Text(reading.detail).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func tint(_ level: PermissionReading.Level) -> Color {
        switch level {
        case .allowed: Theme.goodText
        case .notAsked: Theme.cautionText
        case .blocked: Theme.badText
        case .unknown: Color.secondary
        }
    }

    @ViewBuilder
    private var commandLine: some View {
        if command.isAvailable {
            CardSection("Command line", footnote: commandFootnote) {
                CardRow("calopod command") {
                    HStack(spacing: 12) {
                        Text(commandStatus).foregroundStyle(.secondary)
                        commandButtons
                    }
                }
                if let notice = command.notice { CardRow { Banner(kind: .error, text: notice) } }
                if command.confirmingReplace, case .elsewhere(let target) = command.state {
                    CardRow {
                        VStack(alignment: .leading, spacing: 8) {
                            Banner(kind: .caution, text: "~/.local/bin/calopod now points to \(target), such as a source install. Replace it with the copy in this app?")
                            HStack {
                                Button("Replace") { command.install() }
                                Button("Cancel") { command.cancelReplace() }
                            }
                        }
                    }
                }
                if command.showsPathLine {
                    CardRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Add this line to your shell profile so Terminal finds it:")
                                .font(Theme.Fonts.body).foregroundStyle(.secondary)
                            Text(command.pathLine).font(Theme.Fonts.body.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .onAppear { command.refresh() }
        }
    }

    private var commandFootnote: String {
        "Links ~/.local/bin/calopod to the command inside this app, so updating the app updates the command. No administrator password needed."
            + (command.state == .installed
                ? " To go back to a source install, choose Remove, then run ./install from its folder."
                : "")
    }

    private var commandStatus: String {
        switch command.state {
        case .notInstalled: "Not installed"
        case .installed: "Installed"
        case .elsewhere: "Points somewhere else"
        case .broken: "Broken link"
        case .occupied: "Not a link"
        }
    }

    @ViewBuilder
    private var commandButtons: some View {
        switch command.state {
        case .notInstalled: Button("Install") { command.install() }
        case .installed: Button("Remove", role: .destructive) { command.remove() }.buttonStyle(.quiet)
        case .elsewhere: if !command.confirmingReplace { Button("Replace…") { command.install() } }
        case .broken: Button("Repair") { command.install() }
        case .occupied: EmptyView()
        }
    }

    private var appearance: some View {
        CardSection("Appearance", footnote: "System follows your Mac. The change applies right away.") {
            CardRow {
                PillPicker(
                    options: [("System", AppearanceChoice.system), ("Light", .light), ("Dark", .dark)],
                    selection: Binding(get: { settings.appearance }, set: { settings.setAppearance($0) }))
            }
        }
    }

    private var menuBar: some View {
        CardSection(
            "Menu bar",
            footnote: settings.showsMenuBarItem
                ? "Syncing and reminders do not depend on it."
                : "Calopod stays in the Dock when its window is closed, so it can always be reopened. Syncing and reminders keep running."
        ) {
            CardRow("Show Calopod in the menu bar") {
                Toggle("", isOn: Binding(get: { settings.showsMenuBarItem }, set: { settings.setShowsMenuBarItem($0) }))
                    .labelsHidden()
            }
        }
    }

    private var transparency: some View {
        CardSection(
            "Transparency",
            footnote: "Right is more see-through. Reduce transparency in macOS overrides these."
        ) {
            CardRow { slider("Frame", .frame) }
            CardRow { slider("Sidebar", .sidebar) }
            CardRow { slider("Content", .content) }
            CardButtonRow(label: "Reset to defaults") { settings.resetTransparency() } content: {
                Text("Reset to defaults").font(Theme.Fonts.bodyMedium).foregroundStyle(Theme.accent)
            }
        }
    }

    private var windowStyle: some View {
        let options: [(String, WindowStyle)] =
            (WindowStyle.glassAvailable ? [("Glass", .glass)] : []) + [("Frosted", .frosted), ("Solid", .solid)]
        return CardSection("Window style", footnote: windowStyleCaption) {
            CardRow {
                PillPicker(
                    options: options,
                    selection: Binding(get: { settings.windowStyle }, set: { settings.setWindowStyle($0) }))
            }
        }
    }

    private var windowStyleCaption: String {
        var text = WindowStyle.glassAvailable
            ? "Glass shows the desktop through the window. Frosted blurs it more. Solid shows none."
            : "Frosted blurs the desktop behind the window. Solid shows none. Glass needs macOS 26 or later."
        if settings.windowStyle != settings.launchWindowStyle { text += " Takes effect next time you open Calopod." }
        return text
    }

    private func slider(_ title: String, _ layer: GlassLayer) -> some View {
        let position = Binding(get: { settings.position(layer) }, set: { settings.setPosition(layer, $0) })
        return HStack(spacing: 12) {
            Text(title).font(Theme.Fonts.bodyMedium).frame(width: 70, alignment: .leading)
            Slider(value: position, in: 0 ... 1)
            Text("\(Int((position.wrappedValue * 100).rounded()))%")
                .font(Theme.Fonts.body.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) transparency")
    }
}
