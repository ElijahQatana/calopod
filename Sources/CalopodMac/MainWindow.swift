import AppKit
import SwiftUI

struct MainWindow: View {
    let navigation: AppNavigation
    let sidebar: SidebarState
    let service: ServiceModel
    let setup: SetupModel
    let inbox: InboxModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(
                navigation: navigation, state: sidebar, service: service,
                inboxCount: inbox.count)
            detail
        }
        .padding(Sidebar.inset)
        .ignoresSafeArea(.container, edges: .top)
        .modifier(WindowBackdrop())
        .background { WindowBlurHelper() }
        .background { WindowChrome(collapsed: sidebar.isCollapsed) }
        .navigationTitle(navigation.selection.title)
        .frame(minWidth: 860, minHeight: 580)
        .tint(Theme.accent)
        .appTypography()
    }

    private var detail: some View { DetailPane(sidebar: sidebar) { screen } }

    @ViewBuilder
    private var screen: some View {
        switch navigation.selection {
        case .overview: OverviewScreen(model: service, navigation: navigation, setup: setup)
        case .calendar: CalendarScreen(openInbox: { navigation.openInbox(.changed) })
        case .inbox: InboxScreen(model: inbox, navigation: navigation, colors: .shared)
        case .calendars: CalendarsScreen(model: setup)
        case .arms: ArmsScreen(model: setup)
        case .service: ServiceScreen(model: service)
        case .settings: SettingsScreen()
        }
    }
}

/// The rounded panel a screen sits in. Every screen puts its title on the collapse button's row,
/// so the button floats over the page instead of taking a row of its own above it.
struct DetailPane<Content: View>: View {
    let sidebar: SidebarState
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.sidebarCollapsed, sidebar.isCollapsed)
            .overlay(alignment: .topLeading) {
                if sidebar.isCollapsed {
                    toggleRow.transition(.opacity)
                }
            }
            .panelFill(.card, in: shape)
            .clipShape(shape)
            .panelChrome(shape)
            .padding(.leading, Sidebar.inset)
    }

    private var toggleRow: some View {
        HStack { SidebarToggle(state: sidebar); Spacer() }
            .padding(.leading, Theme.Page.toggleLeading).padding(.trailing, Theme.Page.toggleLeading)
            .padding(.top, Theme.Page.toggleTop)
            .fixedSize(horizontal: false, vertical: true)
    }
}
