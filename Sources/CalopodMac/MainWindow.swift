import SwiftUI

/// The app's one window: a sidebar of screens and the selected screen beside it.
struct MainWindow: View {
    let navigation: AppNavigation
    let service: ServiceModel
    let setup: SetupModel
    let conflicts: ConflictModel

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(Screen.allCases, selection: $navigation.selection) { screen in
                Label(screen.title, systemImage: screen.symbol)
                    .badge(badge(for: screen))
                    .tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) { sidebarStatus }
        } detail: {
            switch navigation.selection {
            case .overview: OverviewScreen(model: service, conflicts: conflicts, navigation: navigation)
            case .calendars: CalendarsScreen(model: setup)
            case .arms: ArmsScreen(model: setup)
            case .conflicts: ConflictsScreen(model: conflicts)
            case .service: ServiceScreen(model: service)
            }
        }
        .navigationTitle(navigation.selection.title)
        .frame(minWidth: 860, minHeight: 580)
        .tint(Theme.accent)
        .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    private func badge(for screen: Screen) -> Int {
        screen == .conflicts ? (conflicts.board?.groups.count ?? 0) : 0
    }

    private var sidebarStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        switch service.status?.state {
        case "ok": Theme.good
        case "paused", "disabled": Theme.caution
        case "failed", "stopped": Theme.bad
        default: .secondary
        }
    }

    private var statusText: String {
        switch service.status?.state {
        case "ok": "Syncing"
        case "paused": "Paused"
        case "disabled": "Sync off"
        case "failed": "Needs attention"
        case "stopped": "Stopped"
        case "not-installed": "Not set up"
        default: "Checking…"
        }
    }
}
