import SwiftUI

struct MainWindow: View {
    let navigation: AppNavigation
    let sidebar: SidebarState
    let service: ServiceModel
    let setup: SetupModel
    let conflicts: ConflictModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(
                navigation: navigation, state: sidebar, service: service,
                inboxCount: conflicts.board?.groups.count ?? 0)
            detail
        }
        .padding(Sidebar.inset)
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .underPageBackgroundColor))
        .background { WindowChrome(collapsed: sidebar.isCollapsed) }
        .navigationTitle(navigation.selection.title)
        .frame(minWidth: 860, minHeight: 580)
        .tint(Theme.accent)
        .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    private var detail: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return screen
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                if sidebar.isCollapsed {
                    HStack { SidebarToggle(state: sidebar); Spacer() }
                        .padding(.horizontal, 14).padding(.top, 12)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(shape)
            .overlay(shape.strokeBorder(.separator))
            .padding(.leading, Sidebar.inset)
    }

    @ViewBuilder
    private var screen: some View {
        switch navigation.selection {
        case .overview: OverviewScreen(model: service, conflicts: conflicts, navigation: navigation)
        case .calendar: CalendarScreen()
        case .inbox:
            PlaceholderScreen(
                screen: .inbox, detail: "Events that need your attention will collect here.",
                action: ("Review overlapping events", { navigation.selection = .conflicts }))
        case .calendars: CalendarsScreen(model: setup)
        case .arms: ArmsScreen(model: setup)
        case .conflicts: ConflictsScreen(model: conflicts)
        case .service: ServiceScreen(model: service)
        }
    }
}
